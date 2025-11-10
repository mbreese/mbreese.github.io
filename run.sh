#!/bin/bash
cd $(dirname $0)
if [ ! -e .venv ] ; then
	python3 -m venv .venv
	.venv/bin/pip install zensical
fi

if [ -e .cache/ ]; then
	rm -rf .cache
fi

.venv/bin/zensical serve
