#!/usr/bin/env python

import argparse
import os.path
import subprocess

"""qcout2xyz.py: take a batch of Q-Chem output files and extract final geometries from them."""
s = "obabel -iqcout {}.qcout -oxyz -O {}.xyz"

parser = argparse.ArgumentParser()
parser.add_argument(dest="filenames", nargs='+')
args = parser.parse_args()
filenames = args.filenames

stubs = list(os.path.splitext(filename)[0] for filename in filenames if os.path.splitext(filename)[1] == '.qcout')

for stub in stubs:
    subprocess.call(s.format(stub, stub).split())
