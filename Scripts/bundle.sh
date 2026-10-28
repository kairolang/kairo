#!/bin/sh
# bundle.sh <tree> [<tree>...]
#
# Makes a staged build tree (Scripts/stage_tree.py) relocatable: every
# non-system shared library the binaries need is copied into <tree>/lib, every
# RUNPATH is made $ORIGIN-relative, and the gates below fail the run if the
# tree still depends on where it was built. Linux only (ldd, patchelf).
#
# Runs after stage_tree.py as kbld's post-build hook (build.k), for debug and
# release alike.
#
# Changes from the original script, each for a tree it would have broken:
#   - patchelf only where the RUNPATH differs: rewriting a file in place
#     corrupts a process that has it mapped (a lit run holding libLLVM), and
#     every build would otherwise rewrite 250 MB of binaries for nothing.
#   - ELF files with no dynamic section (a static musl kairo) are skipped:
#     patchelf rejects them and they have nothing to resolve.
#   - lib/std may be a symlink into the source tree (a debug tree); the draft
#     strip skips it then, or it would delete the tracked Lib/std drafts.
#   - the loader's ldd line names it by path (/lib64/ld-linux-x86-64.so.2),
#     so SYS matches the basename; the path form matched nothing and was
#     copied to $LIB//lib64/..., which fails.
#   - musl: its loader is ld-musl-<arch>.so.1 and it has no GLIBC_ symbol
#     versions, so the floor reports "none" instead of an empty string.
set -eu

[ $# -ge 1 ] || { echo "usage: bundle.sh <tree> [<tree>...]" >&2; exit 2; }

if ! command -v patchelf >/dev/null 2>&1; then
    echo "bundle: patchelf not found; install it (pacman -S patchelf / apt install patchelf)" >&2
    exit 1
fi

# Libraries expected on every host. Never bundle these. glibc's set, then
# musl's (libc.so is musl's libc and loader at once).
SYS='^(linux-vdso\.so|ld-linux[^ ]*|ld-musl[^ ]*|libc\.so|libc\.musl[^ ]*|libm\.so|libdl\.so|libpthread\.so|librt\.so|libutil\.so|libresolv\.so|libgcc_s\.so|libz\.so|libzstd\.so)'

bundle_one() {
    R=$(cd "$1" && pwd)
    BIN="$R/bin"
    LIB="$R/lib"
    [ -d "$BIN" ] || { echo "bundle: $R has no bin/" >&2; return 1; }
    mkdir -p "$LIB"
    echo "== bundle $R"

    elf_files() {
        for f in "$BIN"/* "$LIB"/*.so*; do
            [ -f "$f" ] && [ ! -L "$f" ] || continue
            head -c4 "$f" | grep -q 'ELF' && echo "$f"
        done
    }
    dynamic() {
        readelf -d "$1" 2>/dev/null | grep -q '(NEEDED)\|(RUNPATH)\|(RPATH)'
    }
    runpath() {
        readelf -d "$1" 2>/dev/null | sed -n 's/.*\(runpath\|rpath\): \[\(.*\)\]/\2/p'
    }

    # 1. Copy non-system deps until nothing new resolves outside $LIB.
    while :; do
        for f in $(elf_files); do
            ldd "$f" 2>/dev/null | awk '/=> \//{n = $1; sub(".*/", "", n); print n, $3}' | while read -r name path; do
                echo "$name" | grep -Eq "$SYS" && continue
                case "$path" in "$LIB"/*) continue ;; esac
                [ -e "$LIB/$name" ] && continue
                cp -L "$path" "$LIB/$name"
                chmod 755 "$LIB/$name"
                echo "bundled $name <- $path"
                echo x >> "$R/.bundle_added"
            done
        done
        if [ -f "$R/.bundle_added" ]; then rm -f "$R/.bundle_added"; else break; fi
    done

    # 2. Normalize RUNPATHs: no absolute paths, no empty entries. bin/ (kairo,
    #    kcc, clang-<ver>, lld, llvm-*) reaches lib/ from above it.
    for f in $(elf_files); do
        dynamic "$f" || continue
        case "$f" in
            "$BIN"/*) want='$ORIGIN/../lib' ;;
            *)        want='$ORIGIN' ;;
        esac
        [ "$(runpath "$f")" = "$want" ] && continue
        patchelf --set-rpath "$want" "$f"
        echo "runpath $want: ${f#$R/}"
    done

    # 3. Strip what shouldn't ship.
    rm -f "$BIN"/*.log "$LIB"/liblld*.a
    [ -L "$LIB/std" ] || rm -f "$LIB"/std/v*draft.k

    # 4. Gates.
    fail=0
    if find "$R" -xtype l | grep .; then echo "FAIL: dangling symlinks"; fail=1; fi
    for f in $(elf_files); do
        if env -u LD_LIBRARY_PATH ldd "$f" 2>&1 | grep -q 'not found'; then
            echo "FAIL: unresolved deps in $f"; fail=1
        fi
        rp=$(runpath "$f")
        case "$rp" in
            *:|*::*|:*|*/mnt/*|*/home/*) echo "FAIL: bad RUNPATH '$rp' in $f"; fail=1 ;;
        esac
    done
    floor=$(for f in $(elf_files); do objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*'; done | sort -uV | tail -1)
    echo "glibc floor: ${floor:-none (no GLIBC_ symbol versions: musl or static)}"
    [ "$fail" -eq 0 ] && echo OK || return 1
}

# One tree per process: a function called from `||` runs with set -e off,
# so a failed cp or patchelf would not stop the run.
if [ $# -gt 1 ]; then
    status=0
    for t in "$@"; do sh "$0" "$t" || status=1; done
    exit $status
fi
if [ ! -d "$1/bin" ]; then echo "bundle: skip $1 (not built)"; exit 0; fi
bundle_one "$1"
