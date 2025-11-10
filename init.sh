#!/bin/bash
if [ ! -e .venv ] ; then
python3 -m venv .venv
.venv/bin/pip install zensical
fi
