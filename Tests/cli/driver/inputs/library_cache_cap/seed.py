#!/usr/bin/env python3
"""Seed a cache directory for library_cache_cap.k: two sparse 1 GB entries
stored days ago and one stored now.

    seed.py file DIR   runtime cache entries: DIR/<stem>-1-1.o files
    seed.py tree DIR   library cache entries: DIR/<stem>-1/ directories,
                       aged by their `used` file as a link stamps it
"""
import os
import sys
import time

GB = 1 << 30
DAY = 86400


def sparse(path, size):
    with open(path, "wb") as f:
        f.truncate(size)


def main():
    kind, d = sys.argv[1], sys.argv[2]
    now = time.time()
    for stem, age in (("fakeolder", 3 * DAY), ("fakeold", 2 * DAY), ("fakerecent", 0)):
        at = now - age
        if kind == "file":
            p = os.path.join(d, f"{stem}-1-1.o")
            sparse(p, GB)
            os.utime(p, (at, at))
        else:
            e = os.path.join(d, f"{stem}-1")
            os.makedirs(e, exist_ok=True)
            sparse(os.path.join(e, "blob"), GB)
            used = os.path.join(e, "used")
            open(used, "w").close()
            os.utime(used, (at, at))


if __name__ == "__main__":
    main()
