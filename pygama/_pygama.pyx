from david_decoder cimport *

from libc.stdio cimport *
from libc.string cimport *
from libc.stdint cimport *

from cython.view cimport array as cvarray
cimport numpy as np
import numpy as np
import matplotlib.pyplot as plt
import os, re

import pandas as pd

from future.utils import iteritems

from ._header_parser import *
from .utils import update_progress

WF_LEN = 2018


#Silence harmless warning about saving numpy array to hdf5
import warnings
warnings.filterwarnings(action="ignore", module="pandas", message="^\nyour performance")

update_freq = 2000

def ProcessTier0( filename, output_file_string = "t1", n_max=np.inf):
  cdef FILE       *f_in
  cdef int file_size

  directory = os.path.dirname(filename)

  #parse the header (in python)
  reclen, reclen2, headerDict = parse_header(filename)

  f_in = fopen(filename.encode('utf-8'), "r")
  if f_in == NULL:
    print("Couldn't file the file %s" % filename)
    exit(0)
  #figure out the total size

  fseek(f_in, 0L, SEEK_END);
  file_size = ftell(f_in);
  rewind(f_in);

  #skip the header
  fseek(f_in, reclen*4, SEEK_SET)

  #pull out important header info for event processing
  dataIdRun = get_data_id(headerDict, "ORRunModel", "Run")
  dataIdG   = get_data_id(headerDict, "ORGretina4M", "Gretina4M")
  runNumber = get_run_number(headerDict)

  #read all header info into a single, channel-keyed data frame for saving
  headerinfo = get_header_dataframe_info(headerDict)
  df_channels = pd.DataFrame(headerinfo)
  df_channels.set_index("channel", drop=False, inplace=True)

  cdef np.ndarray[int16_t, ndim=1, mode="c"] narr = np.zeros((WF_LEN), dtype='int16')
  cdef int16_t* sig_ptr
  cdef int16_t [:] sig_arr

  n=0
  res = 0
  cdef uint64_t timestamp
  cdef uint32_t energy
  cdef uint32_t evtdat[20000];
  cdef uint16_t channel;
  cdef int card
  cdef int crate;

  times = []
  energies = []
  appended_data = []
  print("Beginning Tier 0 processing of file {}:".format(filename))

  while (res >=0 and n < n_max):
    #
    update_progress( float(ftell(f_in))/ file_size)

    res = get_next_event(f_in, evtdat, dataIdRun, dataIdG, &card, &crate)
    sig_ptr = parse_event_data(evtdat, &timestamp, &energy, &channel)
    if res ==0: continue

    crate_card_chan = (crate << 12) + (card << 4) + channel

    sig_arr = <int16_t [:WF_LEN]> sig_ptr
    times.append(timestamp)
    energies.append(energy)
    # plt.plot(np.copy(narr))
    data = {}
    data["energy"] = energy
    data["timestamp"] = timestamp
    data["channel"] = crate_card_chan
    data["waveform"] = [np.copy(sig_arr)]

    dr = pd.DataFrame(data, index=[n])

    appended_data.append(dr)
    n+=1;

  fclose(f_in);
  appended_data = pd.concat(appended_data, axis=0)

  t1_file_name = os.path.join(directory, output_file_string+'_run{}.h5'.format(runNumber))
  appended_data.to_hdf(t1_file_name, key="data", mode='w', data_columns=['energy', 'channel', 'timestamp'],)
  df_channels.to_hdf(t1_file_name,   key="channel_info", mode='a', data_columns=True,)

  return appended_data



def ProcessTier1(filename,  processorList, output_file_string="t2",):
  directory = os.path.dirname(filename)

  #snag the run number (assuming filename ends in _run<number>.<filetype>)
  run_str = re.findall('run\d+', filename)[-1]
  runNumber = int(''.join(filter(str.isdigit, run_str)))

  df = pd.read_hdf(filename,key="data")
  appended_data = []
  print("Beginning Tier 1 processing of file {}:".format(filename))
  for i, (index, row) in enumerate(df.iterrows()):
    update_progress( i/ len(df.index))

    #convert the stored waveform (which is int16) to a float, throw it to the processorList
    processorList.Reset( row["waveform"].astype('float32') )

    paramDict = processorList.Process(row)
    dr = pd.DataFrame(paramDict, index=[index])
    appended_data.append(dr)

  appended_data = pd.concat(appended_data, axis=0)

  t2_file_name = os.path.join(directory, output_file_string+'_run{}.h5'.format(runNumber))
  appended_data.to_hdf(t2_file_name, key="data", format='table', mode='w', data_columns=True)
  return appended_data

class TierOneProcessorList():
  def __init__(self):
    self.list = []
    self.waveform_dict = {}
    self.param_dict = {}
    self.t0_list = []

  def Reset(self, waveform):
    self.param_dict = {}
    self.waveform_dict = {"waveform":waveform}

  def Process(self, t0_row):
    for name in self.t0_list:
      self.param_dict[name] = t0_row[name]

    for (type, input, output, fn, perm_args) in self.list:
      #check args list for string vals which match keys in param dict
      args = perm_args.copy() #copy we'll actually pass to the function

      for (arg, val) in iteritems(args):
        if val in self.param_dict.keys():
          args[arg] = self.param_dict[val]

      if input is None: input = "waveform"
      input = self.waveform_dict[input]

      if output is None:
        fn(input, args)

      if type == "transform":
        self.waveform_dict[output] = fn(input, **args)

      elif type == "calculator":
        calc = fn(input, **args)
        if not isinstance(output, str) and len(output) > 1:
          for i, out in enumerate(output):
            self.param_dict[out] = calc[i]
        else: self.param_dict[output] = calc
        # print("    setting {} to {}...".format(output, self.param_dict[output]))

    return self.param_dict

  def AddTransform(self, function, args={}, input_waveform=None, output_waveform=None):
    self.list.append( ("transform", input_waveform, output_waveform, function, args   ) )

  def AddCalculator(self, function, args={}, input_waveform=None,  output_name=None):
    self.list.append( ("calculator", input_waveform, output_name, function, args   ) )

  def AddFromTier0(self, name):
    self.t0_list.append(name)
