#!/bin/sh

# Load xmake environment
source ~/.xmake/profile

# setup xmake for release or debug mode
xmake f -m release

# build and run kairo-tests
xmake -v
