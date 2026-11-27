#!/usr/bin/env python3
"""Add the cross-target sysroots the lit suite compiles for to a tree.

    lit_sysroots.py --repo OWNER/NAME --tag TAG --archive NAME --sums FILE --into DIR

A tree's own sysroot/ holds only its target's roots (the seed archive's, or
Darwin's from ci-deps), but the suite also compiles for Linux (gnu and musl),
wasi, windows-gnu and Darwin targets everywhere. With no root, the compiler
builds one through ksys on first use; on Windows that ran past lit's per-test
limit. The archive (ci-deps) holds those roots with no symlinks, so it unpacks
the same on every runner. A root DIR already has is kept: it is the one the
tree was built and staged with.

Portable on purpose: it needs neither gh nor the zstd tool (the REST API with
GH_TOKEN; zstd if on PATH, else the zstandard module).
"""
import argparse, hashlib, io, json, os, shutil, subprocess, sys, tarfile, urllib.request


def api(url, token, accept="application/vnd.github+json"):
    req = urllib.request.Request(url, headers={"Accept": accept, "X-GitHub-Api-Version": "2022-11-28"})
    # Not carried across the redirect to the storage URL, which refuses a second
    # credential.
    req.add_unredirected_header("Authorization", f"Bearer {token}")
    return urllib.request.urlopen(req, timeout=300)


def download(repo, tag, name, token, dest):
    rel = json.load(api(f"https://api.github.com/repos/{repo}/releases/tags/{tag}", token))
    asset = next((a for a in rel["assets"] if a["name"] == name), None)
    if asset is None:
        sys.exit(f"::error::{repo} release {tag} has no asset {name}")
    with api(asset["url"], token, "application/octet-stream") as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)


def tar_stream(path):
    """A readable stream of the tar inside the .tar.zst."""
    if shutil.which("zstd"):
        return subprocess.Popen(["zstd", "-dc", path], stdout=subprocess.PIPE).stdout
    try:
        import zstandard
    except ImportError:
        subprocess.run([sys.executable, "-m", "pip", "install", "--quiet", "zstandard"], check=True)
        import zstandard
    return zstandard.ZstdDecompressor(max_window_size=1 << 27).stream_reader(open(path, "rb"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--archive", required=True)
    ap.add_argument("--sums", required=True)
    ap.add_argument("--into", required=True)
    a = ap.parse_args()

    want = next((l.split()[0] for l in open(a.sums) if l.split()[-1] == a.archive), None)
    if want is None:
        sys.exit(f"::error::{a.sums} has no line for {a.archive}")
    tmp = os.path.join(os.environ.get("RUNNER_TEMP", "."), a.archive)
    download(a.repo, a.tag, a.archive, os.environ["GH_TOKEN"], tmp)
    h = hashlib.sha256()
    with open(tmp, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != want:
        sys.exit(f"::error::{a.archive}: sha256 {h.hexdigest()}, {a.sums} says {want}")

    os.makedirs(a.into, exist_ok=True)
    have = {n for n in os.listdir(a.into) if os.path.isdir(os.path.join(a.into, n))}
    added, kept = set(), set()
    with tarfile.open(fileobj=tar_stream(tmp), mode="r|") as tar:
        for m in tar:
            top = m.name.split("/", 1)[0]
            if top in have:
                kept.add(top)
                continue
            if not (m.isfile() or m.isdir()) or m.name.startswith("/") or ".." in m.name.split("/"):
                sys.exit(f"::error::unexpected member {m.name!r} in {a.archive}")
            tar.extract(m, a.into)
            added.add(top)
    os.remove(tmp)
    print(f"added {len(added)} roots: {' '.join(sorted(added))}")
    if kept:
        print(f"kept the tree's own: {' '.join(sorted(kept))}")


main()
