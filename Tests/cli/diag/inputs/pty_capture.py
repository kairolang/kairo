#!/usr/bin/env python3
"""Run a command with a pseudo-terminal as stdout and stderr and print what it
wrote, with each ESC byte spelled <E> so FileCheck can match colour escapes.

    pty_capture.py CMD [ARG...]
"""
import os
import pty
import subprocess
import sys


def main():
    master, slave = pty.openpty()
    proc = subprocess.Popen(sys.argv[1:], stdout=slave, stderr=slave, stdin=subprocess.DEVNULL)
    proc.wait()
    os.close(slave)
    out = b""
    try:
        while True:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            out += chunk
    except OSError:
        pass
    sys.stdout.write(out.decode(errors="replace").replace("\x1b", "<E>").replace("\r", ""))


if __name__ == "__main__":
    main()
