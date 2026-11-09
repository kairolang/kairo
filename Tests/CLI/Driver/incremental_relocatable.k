// Incremental compilation, phase 1 (Compiler/Spec/Incremental.md#keys-in-the-object):
// every object carries its own cache record and no key holds a path of the
// machine (without -g), so a cache copied to another directory serves a copy
// of the sources in another directory. The record, not where a file came
// from, decides: a store entry that is cut short or whose record names
// another key is a miss, rebuilt and replaced, never served.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cp -r %S/Inputs/incremental %t.d/s
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a0 --cache-dir %t.d/c
//
// Sources and cache both moved: nothing recompiles.
// RUN: cp -r %t.d/s %t.d/moved && cp -r %t.d/c %t.d/other
// RUN: cd %t.d && %kairo -I %t.d/moved %t.d/moved/main.k -o %t.d/a1 --cache-dir %t.d/other --print-stats 2>&1 | %FileCheck %s --check-prefix=NONE
// NONE: [stats] incremental: {{[1-9][0-9]*}} reused, 0 compiled, 0 stored
// RUN: cmp %t.d/a0 %t.d/a1
//
// Only the store (kairo-cache-v<N>/), as a shared object cache would hand it
// over: its objects are enough.
// RUN: mkdir -p %t.d/store && cp -r %t.d/c/kairo-cache-v* %t.d/store/
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a2 --cache-dir %t.d/store --print-stats 2>&1 | %FileCheck %s --check-prefix=NONE
// RUN: cmp %t.d/a0 %t.d/a2
//
// Every store entry cut short: all of them are misses, and are replaced.
// RUN: for f in %t.d/store/kairo-cache-v*/*/objects/*.o; do head -c 200 "$f" > "$f.cut" && mv "$f.cut" "$f"; done
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a3 --cache-dir %t.d/store --print-stats 2>&1 | %FileCheck %s --check-prefix=ALL
// ALL: [stats] incremental: 0 reused, {{[1-9][0-9]*}} compiled, {{[1-9][0-9]*}} stored
// RUN: cmp %t.d/a0 %t.d/a3
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a4 --cache-dir %t.d/store --print-stats 2>&1 | %FileCheck %s --check-prefix=NONE
//
// Every entry overwritten with one of them, so each file name but one holds
// an object whose record names another key: exactly that one is reused.
// RUN: ls %t.d/store/kairo-cache-v*/*/objects/*.o > %t.d/entries
// RUN: for f in $(cat %t.d/entries); do cp "$(head -n 1 %t.d/entries)" "$f.x" && mv "$f.x" "$f"; done
// RUN: cd %t.d && %kairo -I %t.d/s %t.d/s/main.k -o %t.d/a5 --cache-dir %t.d/store --print-stats 2>&1 | %FileCheck %s --check-prefix=ONE
// ONE: [stats] incremental: 1 reused, {{[1-9][0-9]*}} compiled
// RUN: cmp %t.d/a0 %t.d/a5
