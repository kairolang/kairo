#!/usr/bin/env python3
"""Runs a command that cannot create threads and says how it ended.

usage: no_new_threads.py <command> [args...]

The command runs with RLIMIT_NPROC at 1, so every pthread_create in it fails
with EAGAIN. Prints `ended: <exit status>` and the command's stderr, or
`ended: timeout` when it is still running after 30 seconds. root is exempt
from the limit, so there the command is not run and `ended: unlimited` is
printed instead.
"""
import os
import resource
import subprocess
import sys


def limit():
    resource.setrlimit(resource.RLIMIT_NPROC, (1, 1))


def main():
    if os.geteuid() == 0:
        print("ended: unlimited")
        return 0
    try:
        r = subprocess.run(sys.argv[1:], preexec_fn=limit, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=30)
    except subprocess.TimeoutExpired:
        print("ended: timeout")
        return 0
    print(f"ended: {r.returncode}")
    sys.stdout.write(r.stderr.decode("utf-8", errors="replace"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
