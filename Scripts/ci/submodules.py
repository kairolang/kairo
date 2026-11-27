#!/usr/bin/env python3
"""Check out the named submodules (depth 1), retrying when GitHub refuses.

    submodules.py PATH...

A run starts some 30 build jobs at once, and GitHub answers a burst of clones
of the same repositories with HTTP 403 now and then; one refused clone would
fail the job and stop its target's lit. Each attempt waits longer, with jitter
so the jobs do not retry in step.
"""
import random, subprocess, sys, time

TRIES = 6


def main():
    paths = sys.argv[1:]
    if not paths:
        sys.exit("usage: submodules.py PATH...")
    for n in range(1, TRIES + 1):
        r = subprocess.run(["git", "submodule", "update", "--init", "--depth", "1", "--", *paths])
        if r.returncode == 0:
            return 0
        if n == TRIES:
            break
        wait = 15 * n + random.uniform(0, 15)
        print(f"::warning title=submodules::attempt {n} of {TRIES} failed (rc {r.returncode}); "
              f"retrying in {wait:.0f} s", flush=True)
        time.sleep(wait)
    print(f"::error title=submodules::could not check out {' '.join(paths)} after {TRIES} attempts")
    return 1


sys.exit(main())
