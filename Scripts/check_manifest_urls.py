#!/usr/bin/env python3
# Check that every URL in a kairo-sysroots manifest.json resolves.
#
# The v2-llvm22 manifest shipped pointing every target at
# .../releases/download/v1-llvm22/..., a tag that has no assets: each URL
# 404'd while the files sat under v2-llvm22. Nothing noticed, because
# nothing fetched them until a user did. This is the check that would have.
#
# A manifest downloaded from a release must name that release (the bug
# above, in one request). Then per target:
#   - the URL must name the manifest's own release and asset
#     (.../releases/download/<release>/<asset>), which catches a stale tag
#     with no network at all;
#   - an HTTP HEAD, following redirects (GitHub answers 302 to a signed
#     blob URL), must end in 200;
#   - the final Content-Length, when the server sends one, must equal `size`.
# sha256 is not re-hashed: that means downloading ~500 MB, and a wrong
# tag or a missing asset, the failures seen so far, are both caught above.
#
#   python3 Scripts/check_manifest_urls.py                 # the published latest manifest
#   python3 Scripts/check_manifest_urls.py dist/manifest.json
#   python3 Scripts/check_manifest_urls.py https://.../manifest.json --offline
#
# Exit 0 when every URL resolves, 1 otherwise. Standard library only, so CI
# needs nothing installed.
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = "kairolang/kairo-sysroots"
LATEST = f"https://github.com/{REPO}/releases/latest/download/manifest.json"
UA = "kairo-manifest-check/1"


def load(src: str) -> tuple[dict, str | None]:
    """(manifest, the release tag it was downloaded from, if any)."""
    if src.startswith(("http://", "https://")):
        # .../releases/latest/download/ redirects to the tag's own path
        # first; that hop is what names the tag (the next one is a blob).
        hops = [src]

        class Record(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                hops.append(newurl)
                return super().redirect_request(req, fp, code, msg, headers, newurl)

        req = urllib.request.Request(src, headers={"User-Agent": UA})
        with urllib.request.build_opener(Record).open(req, timeout=60) as r:
            m = json.load(r)
        tag = next((t.group(1) for u in hops
                    if (t := re.search(r"/releases/download/([^/]+)/", u))), None)
        return m, tag
    return json.loads(Path(src).read_text()), None


def head(url: str, tries: int = 3) -> tuple[int, int | None, str]:
    """(status, content-length, error). Retries only what may be transient."""
    err = ""
    for i in range(tries):
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                n = r.headers.get("Content-Length")
                return r.status, int(n) if n and n.isdigit() else None, ""
        except urllib.error.HTTPError as e:
            if e.code < 500 and e.code != 429:
                return e.code, None, ""  # a 404 is an answer, not a hiccup
            err = f"HTTP {e.code}"
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            err = str(getattr(e, "reason", e))
        time.sleep(2 ** i)
    return 0, None, err


def check(m: dict, tag: str | None, offline: bool) -> list[str]:
    release = m.get("release")
    targets = m.get("targets") or {}
    fails = []
    if not release:
        fails.append("manifest has no 'release'")
    elif tag and release != tag:
        # The v1-in-v2 bug, caught without a request per target: the
        # manifest names a release other than the one it is published in.
        fails.append(f"manifest says release {release!r} but is published under {tag!r}")
    if not targets:
        fails.append("manifest has no targets")

    want = {}
    for name, t in sorted(targets.items()):
        url, asset = t.get("url"), t.get("asset")
        if not url or not asset:
            fails.append(f"{name}: missing 'url' or 'asset'")
            continue
        expect = f"/releases/download/{release}/{asset}"
        if not url.endswith(expect):
            fails.append(f"{name}: url does not name release {release!r} / asset {asset!r}: {url}")
        want[name] = t
    if offline:
        return fails

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = dict(zip(want, pool.map(lambda t: head(t["url"]), want.values())))
    for name, (status, length, err) in results.items():
        t = want[name]
        if status != 200:
            fails.append(f"{name}: {t['url']} -> {status or err}")
        elif length is not None and t.get("size") is not None and length != t["size"]:
            fails.append(f"{name}: size {length} at {t['url']}, manifest says {t['size']}")
        else:
            print(f"ok   {name} ({length} bytes)" if length is not None else f"ok   {name} (size unverified)")
    return fails


def main() -> None:
    ap = argparse.ArgumentParser(description="Check that every URL in a sysroot manifest.json resolves.")
    ap.add_argument("manifest", nargs="*", default=[LATEST], help=f"path or URL (default: {LATEST})")
    ap.add_argument("--offline", action="store_true", help="only check that each URL names the manifest's release")
    a = ap.parse_args()

    bad = 0
    for src in a.manifest:
        print(f"== {src}")
        try:
            m, tag = load(src)
        except (OSError, ValueError, urllib.error.URLError) as e:
            print(f"FAIL cannot read manifest: {e}")
            bad += 1
            continue
        fails = check(m, tag, a.offline)
        for f in fails:
            print(f"FAIL {f}")
        n = len(m.get("targets") or {})
        print(f"{src}: {n} targets, {'OK' if not fails else f'{len(fails)} failing'}")
        bad += len(fails)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
