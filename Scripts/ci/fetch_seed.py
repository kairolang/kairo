#!/usr/bin/env python3
"""Download the pinned seed release archive, verify its SHA-256, unpack it.

    fetch_seed.py --tag v0.3.0 --archive NAME --sums FILE --out DIR [--repo OWNER/REPO]

Prints the unpacked tree's root (the directory holding bin/), or with --raw the
verified archive's path. The archive comes from `gh release download` (GH_TOKEN
names the credential), or from --from DIR when it exists there.
"""
import argparse, hashlib, os, shutil, subprocess, sys, tarfile, zipfile


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--archive", required=True)
    ap.add_argument("--sums", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", default="kairolang/kairo")
    ap.add_argument("--from", dest="src")
    ap.add_argument("--raw", action="store_true", help="verify only; print the archive path")
    a = ap.parse_args()

    want = None
    for line in open(a.sums):
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("*") == a.archive:
            want = parts[0].lower()
    if not want:
        sys.exit(f"{a.archive} is not in {a.sums}")

    os.makedirs(a.out, exist_ok=True)
    arc = os.path.join(a.out, a.archive)
    if a.src:
        shutil.copy(os.path.join(a.src, a.archive), arc)
    else:
        subprocess.run(["gh", "release", "download", a.tag, "-R", a.repo,
                        "-p", a.archive, "-D", a.out, "--clobber"], check=True)
    got = sha256(arc)
    if got != want:
        sys.exit(f"{a.archive}: sha256 {got} != pinned {want}")

    if a.raw:
        print(arc)
        return
    dest = os.path.join(a.out, "tree")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    if arc.endswith(".zip"):
        if shutil.which("unzip"):
            # zipfile drops executable bits and turns symlinks into files; unzip keeps both.
            subprocess.run(["unzip", "-q", arc, "-d", dest], check=True)
        else:
            zipfile.ZipFile(arc).extractall(dest)
    else:
        with tarfile.open(arc) as t:
            t.extractall(dest)
    entries = [e for e in os.listdir(dest)]
    root = os.path.join(dest, entries[0]) if len(entries) == 1 and os.path.isdir(os.path.join(dest, entries[0])) else dest
    print(root)


main()
