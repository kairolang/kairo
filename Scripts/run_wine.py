#!/usr/bin/env python3
"""Run a Windows executable under Wine with a private prefix.

    run_wine.py <exe> [args...]

Wine is taken from $KAIRO_WINE, then PATH, then the copies shipped inside
Steam's Proton. Proton's Wine needs nothing beyond the prefix and WINEDEBUG. The prefix is <repo>/build/wine-prefix (override with
$KAIRO_WINE_PREFIX); a user's own prefixes are never touched. stdout, stderr
and the exit code of the program are forwarded. Exit 127 when no Wine is
found.
"""
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTON_NAMES = ["Proton - Experimental", "Proton Hotfix", "Proton 9.0 (Beta)"]


def _steam_roots():
    home = os.path.expanduser("~")
    return [
        os.path.join(home, ".local/share/Steam/steamapps/common"),
        os.path.join(home, ".steam/steam/steamapps/common"),
        os.path.join(home, ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common"),
    ]


def find_wine():
    """Returns (wine_binary, files_dir_or_None)."""
    env = os.environ.get("KAIRO_WINE")
    if env and os.path.isfile(env):
        return env, _proton_files(env)
    for name in ("wine64", "wine"):
        p = shutil.which(name)
        if p:
            return p, None
    for root in _steam_roots():
        for n in PROTON_NAMES:
            files = os.path.join(root, n, "files")
            w = os.path.join(files, "bin", "wine")
            if os.path.isfile(w):
                return w, files
    return None, None


def _proton_files(wine):
    files = os.path.dirname(os.path.dirname(os.path.abspath(wine)))
    return files if os.path.isdir(os.path.join(files, "lib")) else None


def make_env(files):
    env = dict(os.environ)
    env["WINEPREFIX"] = os.environ.get("KAIRO_WINE_PREFIX") or os.path.join(REPO, "build", "wine-prefix")
    env["WINEDEBUG"] = "-all"
    env.setdefault("WINEDLLOVERRIDES", "winemenubuilder.exe=d;mscoree,mshtml=")
    return env


def main(argv):
    if not argv:
        sys.stderr.write("usage: run_wine.py <exe> [args...]\n")
        return 2
    wine, files = find_wine()
    if not wine:
        sys.stderr.write("run_wine.py: no wine found (set KAIRO_WINE, put wine on PATH, or install Steam Proton)\n")
        return 127
    env = make_env(files)
    os.makedirs(env["WINEPREFIX"], exist_ok=True)
    sys.stdout.flush()
    try:
        # Proton's wineserver prints a banner on stderr; it is not the
        # program's output, so it is dropped.
        p = subprocess.Popen([wine] + argv, env=env, stderr=subprocess.PIPE)
        banner = False
        for line in p.stderr:
            if line.startswith(b"wineserver: using "):
                banner = True
                continue
            if banner and not line.strip():
                banner = False
                continue
            banner = False
            sys.stderr.buffer.write(line)
            sys.stderr.buffer.flush()
        return p.wait()
    except OSError as e:
        sys.stderr.write("run_wine.py: cannot run %s: %s\n" % (wine, e))
        return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
