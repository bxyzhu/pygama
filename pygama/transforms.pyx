import numpy as np
import pandas as pd
from scipy.ndimage.filters import gaussian_filter1d
from scipy import signal

from .filters import *

#Silence harmless warning you get using savgol on old LAPACK
import warnings
warnings.filterwarnings(action="ignore", module="scipy", message="^internal gelsd")

#Finds average baseline from first [samples] number of samples
def remove_baseline(waveform, bl_0=0, bl_1=0):
    return (waveform - (bl_0 + bl_1*np.arange(len(waveform))))

def center(waveform, center_index, n_samples_before, n_samples_after):
  return waveform[center_index - n_samples_before : center_index+ n_samples_before]

def savgol_filter(waveform, window_length=47, order=2):
  return signal.savgol_filter(waveform, window_length, order)

def pz_correct(waveform, rc_1=70, rc_2=0, rc1_frac=1, digFreq=100E6):
    ''' RC params are in us'''
    #get the linear filter parameters.
    if rc_2==0 or rc1_frac == 1:
        num, den = rc_decay(rc_1, digFreq)
    else:
        num, den = rc_decay_2pole(rc_1, rc_2, rc1_frac, digFreq)

    #reversing num and den does the inverse transform (ie, PZ corrects)
    return signal.lfilter(den, num, waveform)

def trap_filter(waveform, rampTime=400, flatTime=200, decayTime=0., baseline = 0.):
    """ Apply a trap filter to a waveform. """
    decayConstant = 0.
    norm = rampTime
    if decayTime != 0:
        decayConstant = 1./(np.exp(1./decayTime) - 1)
        norm *= decayConstant

    trapOutput = np.zeros_like(waveform)
    fVector = np.zeros_like(waveform)
    scratch = np.zeros_like(waveform)

    fVector[0] = waveform[0] - baseline
    trapOutput[0] = (decayConstant+1.)*(waveform[0] - baseline)

    wf_minus_ramp = np.zeros_like(waveform)
    wf_minus_ramp[:rampTime] = baseline
    wf_minus_ramp[rampTime:] = waveform[:len(waveform)-rampTime]

    wf_minus_ft_and_ramp = np.zeros_like(waveform)
    wf_minus_ft_and_ramp[:(flatTime+rampTime)] = baseline
    wf_minus_ft_and_ramp[(flatTime+rampTime):] = waveform[:len(waveform)-flatTime-rampTime]

    wf_minus_ft_and_2ramp = np.zeros_like(waveform)
    wf_minus_ft_and_2ramp[:(flatTime+2*rampTime)] = baseline
    wf_minus_ft_and_2ramp[(flatTime+2*rampTime):] = waveform[:len(waveform)-flatTime-2*rampTime]

    scratch = waveform - (wf_minus_ramp + wf_minus_ft_and_ramp + wf_minus_ft_and_2ramp )

    if decayConstant != 0:
        fVector = np.cumsum(fVector + scratch)
        trapOutput = np.cumsum(trapOutput +fVector+ decayConstant*scratch)
    else:
        trapOutput = np.cumsum(trapOutput + scratch)

    # Normalize and resize output
    trapOutput[:len(waveform) - (2*rampTime+flatTime)] = trapOutput[2*rampTime+flatTime:]/norm
    trapOutput.resize( (len(waveform) - (2*rampTime+flatTime)))
    return trapOutput

def notch_filter(waveform, notch_freq, qual_factor = 10, f_dig = 1E8, ):
    nyquist = 0.5*f_dig
    w0 = notch_freq/nyquist

    #"quality factor" which determines width of notch
    Q = qual_factor

    num, den = signal.iirnotch(w0, Q)
    return signal.lfilter(num, den, waveform)

def asym_trap_filter(waveform,ramp=200,flat=100,fall=40,padAfter=False):
    """ Computes an asymmetric trapezoidal filter """
    trap = np.zeros(len(waveform))
    for i in range(len(waveform)-1000):
        w1 = ramp
        w2 = ramp+flat
        w3 = ramp+flat+fall
        r1 = np.sum(waveform[i:w1+i])/(ramp)
        r2 = np.sum(waveform[w2+i:w3+i])/(fall)
        if not padAfter:
            trap[i+1000] = r2 - r1
        else:
            trap[i] = r2 - r1
    return trap

def nonlinearity_correct(waveform, time_constant_samples, fNLCMap, fNLCMap2 = None, n_bl=100):

  map_offset = np.int((len(fNLCMap) - 1)/2)

  if (time_constant_samples == 0.):
    waveform -= fNLCMap.GetCorrection();
  else:
    # // Apply Radford's time-lagged correction
    #
    # // first, average baseline at the beginning to get a good starting
    # // point for current_inl

    if(n_bl >= len(waveform)):
      print("input wf length is only {}".format(len(waveform)))
      return

    # // David initializes bl to nBLEst/2 to get good rounding when he does integer division
    # // by nBLEst, but we do floating point division so that's not necessary

    try:
      bl = np.int( np.sum(waveform[:n_bl])/n_bl )
      current_inl = fNLCMap[bl + map_offset];

      for i in range(n_bl, len(waveform)):
        wf_pt_int = np.int(waveform[i])
        if wf_pt_int + map_offset >= len(fNLCMap): continue

        summand = fNLCMap[ wf_pt_int + map_offset ];
        current_inl += (summand - current_inl) / time_constant_samples;
        if(fNLCMap2 is None): waveform[i] -= current_inl;
        else: waveform[i] -= fNLCMap2[ wf_pt_int+ map_offset ] + current_inl; # maybe needs to be +=! check

    except IndexError:
        print("\nadc value {} and int {}".format(waveform[i], wf_pt_int))
        print("wf_offset {}".format(map_offset))
        print("looking for index {}/{}".format(wf_pt_int + map_offset, len(fNLCMap)))

  return waveform
