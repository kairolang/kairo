// Registry schema 2 (build/sysroot-share/FORMAT.md, "schema 2"): a share
// input holds no symlinks, so a zip extracted on Windows hashes as a Linux untar
// does. tree_sha256 walks without following links and a link inside an input is
// refused with its path; links.tsv rows come back as the same symlinks when an
// input subdir is copied into a root, casefold.tsv rows as their real names, and
// neither file reaches the root. Schema 1 shares keep working; any other schema
// is refused by name.
//
// The fixture is a one-input bundle share for x86_64-unknown-freebsd with no
// runtimes registered: the libc-headers stage (the bundle copy) runs and is kept
// in the cache, and the builtins stage refuses after it, so the copy can be
// inspected without compiling anything.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, shell, host-linux
// RUN: rm -rf %t && mkdir -p %t/s/families %t/s/runtimes %t/s/base/usr/lib %t/s/base/usr/include/sub
// RUN: %ksys --print-runtimes-revision > %t/s/runtimes/REVISION
// RUN: printf 'family = "freebsd"\ntriple = "{arch}-unknown-freebsd"\nos_version = "14.4"\ninputs = ["base"]\nruntimes = []\n\n[bundle_layout]\n"usr" = "usr"\n\n[toml]\ntriple = "{triple}"\nsysroot = "."\ninclude_dirs = ["usr/include"]\nlib_dirs = ["usr/lib"]\n' > %t/s/families/freebsd.toml
// RUN: printf 'libc\n' > %t/s/base/usr/lib/libc.a && printf 'lower\n' > %t/s/base/usr/include/xt_mark.h
// RUN: printf 'upper\n' > %t/s/base/usr/include/xt_MARK.h.kcase && printf 'deep\n' > %t/s/base/usr/include/sub/a.h
// RUN: printf 'usr/include/link.h\tsub/a.h\tf\nusr/lib/include\t../include\td\nusr/lib/libc.so\tlibc.so.7\tf\nusr/lib/libc.so.7\tlibc.a\tf\n' > %t/s/base/links.tsv
// RUN: printf 'usr/include/xt_MARK.h.kcase\tusr/include/xt_MARK.h\n' > %t/s/base/casefold.tsv
// RUN: python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import ship_sysroot_inputs as s; from pathlib import Path; print('schema = 2\n\n[inputs]\n\x22base\x22 = \x22' + s.tree_sha256(Path(sys.argv[2]), legacy=False) + '\x22\n\n[licenses]\n\x22base\x22 = \x22BSD-2-Clause\x22')" %S/../../../Scripts %t/s/base > %t/s/registry.toml
//
// RUN: %ksys --share %t/s verify-share | %FileCheck %s --check-prefix=VERIFY
// VERIFY: ok        base
//
// RUN: { %ksys --share %t/s --cache %t/cache ensure x86_64-unknown-freebsd 2>&1; echo "exit $?"; } > %t/ensure.out
// RUN: %FileCheck %s --check-prefix=ENSURE < %t/ensure.out
// ENSURE:      ksys: x86_64-unknown-freebsd: stage libc-headers
// ENSURE-NEXT: ksys: x86_64-unknown-freebsd: stage builtins
// ENSURE-NEXT: ksys: error [P009E]: share input runtimes-recipe is not listed in {{.*}}registry.toml
// ENSURE:      exit 2
// RUN: cd %t/cache/stage/libc-headers-*/out/usr && test "$(readlink lib/libc.so)" = libc.so.7 && test "$(readlink lib/libc.so.7)" = libc.a
// RUN: cd %t/cache/stage/libc-headers-*/out/usr && test "$(readlink lib/include)" = ../include && test "$(cat lib/include/sub/a.h)" = deep
// RUN: cd %t/cache/stage/libc-headers-*/out/usr && test "$(readlink include/link.h)" = sub/a.h && test "$(cat lib/libc.so)" = libc
// RUN: cd %t/cache/stage/libc-headers-*/out/usr && test "$(cat include/xt_MARK.h)" = upper && test "$(cat include/xt_mark.h)" = lower
// RUN: cd %t/cache/stage/libc-headers-*/out && test ! -e usr/include/xt_MARK.h.kcase && test ! -e links.tsv && test ! -e casefold.tsv
//
// A symlink inside a schema 2 input is refused by path, by verify-share and by a build.
// RUN: ln -s libc.a %t/s/base/usr/lib/stray.a
// RUN: { %ksys --share %t/s verify-share 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=LINK
// LINK:      ERROR     base
// LINK-NEXT: ksys: error [P009E]: share input {{.*}}/base/usr/lib/stray.a is a symlink; a schema 2 input holds none (links.tsv records them)
// LINK-NEXT: exit 2
// RUN: { %ksys --share %t/s --cache %t/cache2 ensure x86_64-unknown-freebsd 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=LINKB
// LINKB:      ksys: error [P009E]: share input {{.*}}/base/usr/lib/stray.a is a symlink; a schema 2 input holds none (links.tsv records them)
// LINKB-NEXT: exit 2
// RUN: rm %t/s/base/usr/lib/stray.a
//
// The input root itself may be a link (a share view links whole inputs in).
// RUN: mv %t/s/base %t/base.real && ln -s %t/base.real %t/s/base
// RUN: %ksys --share %t/s verify-share | %FileCheck %s --check-prefix=VERIFY
//
// RUN: sed -i 's/^schema = 2/schema = 3/' %t/s/registry.toml
// RUN: { %ksys --share %t/s verify-share 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=SCHEMA
// SCHEMA:      ksys: error [P009E]: share input {{.*}}registry.toml: schema is '3', this ksys reads schema 1 and 2
// SCHEMA-NEXT: ksys: note [P009N]: {{.*}}
// SCHEMA-NEXT: exit 2
