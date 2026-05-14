import kairo_demangle as kd

import lldb
import re
import subprocess

def demangle_frame(frame, internal_dict):
    """Entry point for LLDB frame formatting"""
    mangled = frame.GetFunctionName()
    if not mangled: return "unknown"
    return kd.process_line(mangled)

def __lldb_init_module(debugger, internal_dict):
    # This ensures LLDB knows the script is loaded
    pass