#!/bin/bash

# Initialize an empty variable to collect the remaining arguments
ARGS=""
IS_LLDB=false
IS_GDB=false

# Get the path to the binary using xmake, and strip ANSI color codes using sed
PATH_TO_BINARY=$(xmake show -t helix | sed 's/\x1b\[[0-9;]*m//g' | awk '/targetfile/ {print $2}')

# Use realpath to get the canonical path and concat with the current directory
PATH_TO_BINARY=$(realpath "$(pwd)/$PATH_TO_BINARY")

# if the first arg is '-lldb' then echo the lldb command to run the binary
if [ "$1" == "-lldb" ]; then
    shift # remove the '-lldb'
    IS_LLDB=true
fi
if [ "$1" == "-gdb" ]; then
    shift # remove the '-gdb'
    IS_GDB=true
fi

# Check if the first argument is '--'
if [ "$1" == "--" ]; then
    # Shift to remove the '--'
    shift
else
    # Build the Helix project using xmake
    xmake
fi

# Collect all the remaining arguments after '--'
while [ "$1" != "" ]; do
    ARGS="$ARGS $1"
    shift
done

if [ "$IS_LLDB" = true ]; then
    lldb $PATH_TO_BINARY -o "settings set target.run-args $ARGS"
    exit 0
fi
if [ "$IS_GDB" = true ]; then
    gdb $PATH_TO_BINARY -ex "set args $ARGS"
    exit 0
fi

# Run the binary with the remaining arguments
$PATH_TO_BINARY $ARGS
