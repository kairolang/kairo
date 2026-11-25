#!/usr/bin/env python3
"""Seed a library cache directory for library_cache_copy_leftover.k with
leftover `.copy-` trees, each aged by the `manifest` its copy carries:

    lib-1.copy-901   3 GB, three hours old   (past the cap: evicted)
    lib-1.copy-902   1 MB, two hours old     (under the cap once 901 is gone)
    lib-1.copy-903   1 GB, stored now        (inside the last hour: kept)
    lib-1.copy-904   1 MB, two days old      (past the one-day age bound)

The blobs are sparse: their size counts, their disk does not.
"""
import os
import sys
import time

MB = 1 << 20
GB = 1 << 30
HOUR = 3600


def main():
    d = sys.argv[1]
    now = time.time()
    for pid, size, age in ((901, 3 * GB, 3 * HOUR), (902, MB, 2 * HOUR),
                           (903, GB, 0), (904, MB, 48 * HOUR)):
        e = os.path.join(d, f"lib-1.copy-{pid}")
        os.makedirs(e, exist_ok=True)
        with open(os.path.join(e, "blob"), "wb") as f:
            f.truncate(size)
        manifest = os.path.join(e, "manifest")
        open(manifest, "w").close()
        at = now - age
        os.utime(manifest, (at, at))


if __name__ == "__main__":
    main()
