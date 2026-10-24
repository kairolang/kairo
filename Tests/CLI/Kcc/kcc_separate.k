// Separate compilation, as with clang: `kcc -c x.cc` treats the .k it
// includes as a header (analysed for the stream, no object), `kcc -c y.k`
// writes y.o and nothing for what y imports, and a link of the objects
// takes builtin, std and the runtime from the toolchain's library, which
// the first link builds into $KAIRO_CACHE_DIR.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d

// 3 + 4, then hits 2 and 2 + 3; the destructor runs at the C++ scope end.
// RUN: %kcc -c %S/Inputs/use_shapes.cc -o %t.d/x.o
// RUN: %kcc -c %S/Inputs/shapes.k -o %t.d/y.o
// RUN: test "$(ls %t.d)" = "$(printf 'x.o\ny.o')"
// RUN: %kcc %t.d/x.o %t.d/y.o -o %t.d/main
// RUN: %t.d/main > %t.d/main.out; test $? -eq 14
// RUN: %FileCheck %s --input-file=%t.d/main.out
// CHECK:      Tracer()
// CHECK-NEXT: ~Tracer()

// Templates across runs: tmpl.o homes Box<i32> and first<i32>, the .cc
// instantiates Box<long> and first<short> itself (no `extern template` in
// an include). 9 + 1 + 7 + 6.
// RUN: %kcc -c %S/Inputs/use_tmpl.cc -o %t.d/ut.o
// RUN: %kcc -c %S/Inputs/tmpl.k -o %t.d/tmpl.o
// RUN: %kcc %t.d/ut.o %t.d/tmpl.o -o %t.d/tmpl
// RUN: %t.d/tmpl; test $? -eq 23

// A MinGW link has no --start-lib: the library comes as libkairo.a, which
// the build writes for a windows-gnu target. Linked only (no Windows to
// run it on): a PE image.
// RUN: %if sysroot-x86_64-windows-gnu %{ %kcc --target=x86_64-windows-gnu -c %S/Inputs/use_shapes.cc -o %t.d/xw.o %}
// RUN: %if sysroot-x86_64-windows-gnu %{ %kcc --target=x86_64-windows-gnu -c %S/Inputs/shapes.k -o %t.d/yw.o %}
// RUN: %if sysroot-x86_64-windows-gnu %{ %kcc --target=x86_64-windows-gnu %t.d/xw.o %t.d/yw.o -o %t.d/main.exe 2>&1 | %FileCheck %s --check-prefix=MINGW --allow-empty %}
// RUN: %if sysroot-x86_64-windows-gnu %{ od -An -c -N2 %t.d/main.exe | grep -q 'M   Z' %}
// MINGW-NOT: warning
// MINGW-NOT: error

// The cache drops libraries no link has used for 30 days, and partial
// builds a day old, whenever it builds one. A private cache, so the
// build is sure to happen.
// RUN: mkdir -p %t.d/kc/lib/old-lib %t.d/kc/lib/fresh-lib %t.d/kc/lib/x.tmp-1
// RUN: touch -d "40 days ago" %t.d/kc/lib/old-lib/used && touch %t.d/kc/lib/fresh-lib/used && touch -d "2 days ago" %t.d/kc/lib/x.tmp-1
// RUN: env KAIRO_CACHE_DIR=%t.d/kc %kcc %t.d/x.o %t.d/y.o -o %t.d/main_gc
// RUN: test ! -e %t.d/kc/lib/old-lib && test ! -e %t.d/kc/lib/x.tmp-1 && test -d %t.d/kc/lib/fresh-lib

// A library whose manifest no longer matches a source it was built from is
// refused and rebuilt: the recorded mtime of builtin's string.k is made
// stale, and the next link writes a manifest with the real one.
// RUN: mkdir -p %t.d/stale
// RUN: env KAIRO_CACHE_DIR=%t.d/stale %kcc %t.d/x.o %t.d/y.o -o %t.d/main_s1
// RUN: sed -i -E 's|^src [0-9]+ (.*/string\.k)$|src 1 \1|' %t.d/stale/lib/*/manifest
// RUN: grep -q '^src 1 .*string\.k$' %t.d/stale/lib/*/manifest
// RUN: env KAIRO_CACHE_DIR=%t.d/stale %kcc %t.d/x.o %t.d/y.o -o %t.d/main_s2
// RUN: not grep -q '^src 1 ' %t.d/stale/lib/*/manifest
// RUN: %t.d/main_s2 > /dev/null; test $? -eq 14

// Two links racing on an empty cache: one renames its library into place,
// the other uses that one. Both link, and one library is left.
// RUN: mkdir -p %t.d/race
// RUN: env KAIRO_CACHE_DIR=%t.d/race %kcc %t.d/x.o %t.d/y.o -o %t.d/race1 & env KAIRO_CACHE_DIR=%t.d/race %kcc %t.d/x.o %t.d/y.o -o %t.d/race2; wait
// RUN: %t.d/race1 > /dev/null; test $? -eq 14
// RUN: %t.d/race2 > /dev/null; test $? -eq 14
// RUN: test "$(ls %t.d/race/lib | grep -v -e '\.tmp-' -e '\.stale-' | wc -l)" -eq 1

// A crashed build's leftovers do not stop the next one.
// RUN: mkdir -p %t.d/crash/lib/junk.tmp-1 && touch %t.d/crash/lib/junk.tmp-1/half.o
// RUN: env KAIRO_CACHE_DIR=%t.d/crash %kcc %t.d/x.o %t.d/y.o -o %t.d/crash_ok && %t.d/crash_ok > /dev/null; test $? -eq 14
