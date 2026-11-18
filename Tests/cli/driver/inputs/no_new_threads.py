#!/usr/bin/env python3
"""Runs a command that cannot create threads and says how it ended.

usage: no_new_threads.py <command> [args...]

The command runs with RLIMIT_NPROC at 1, so every pthread_create in it fails
with EAGAIN. Prints `ended: <exit status>` and the command's stderr, or
`ended: timeout` when it is still running after 30 seconds, and then one
verdict line:

    verdict: reported     exit status 1 and "cannot start worker thread" on stderr
    verdict: unlimited    root is exempt from the limit; the command is not run
    verdict: unexpected   anything else (a crash, a hang, another error, success)
"""
import os
import resource
import subprocess
import sys


def limit():
    resource.setrlimit(resource.RLIMIT_NPROC, (1, 1))


def main():
    if os.geteuid() == 0:
        print("verdict: unlimited")
        return 0
    try:
        r = subprocess.run(sys.argv[1:], preexec_fn=limit, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=30)
    except subprocess.TimeoutExpired:
        print("ended: timeout")
        print("verdict: unexpected")
        return 0
    err = r.stderr.decode("utf-8", errors="replace")
    print(f"ended: {r.returncode}")
    sys.stdout.write(err)
    reported = r.returncode == 1 and "cannot start worker thread" in err
    print("verdict: reported" if reported else "verdict: unexpected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
