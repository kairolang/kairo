// Every command-line input is a root, so each may be a script. Two scripts
// linked into one program would be two `main`s: that is an error naming
// both, at the second one's first statement, before the link runs. Each
// file alone is a fine program, and compiling both without a link (`-c`,
// `--type-check-only`) is no error: nothing joins them into one program.

import std::io::println

println("first")

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %s %S/second.k -o %t.d/both --cache-dir %t.d/c1 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG:      second.k:6:1: error [SC001E]: two script files in one program: 'second.k' and 'first.k' each run top-level statements as 'main'
// DIAG-NEXT: first.k:9:1: note [SC001N]: 'first.k' is a script: its first top-level statement is here
// DIAG-NOT: {{error|warning}}
// RUN: test ! -e %t.d/both
//
// RUN: %kairo %s -o %t.d/one --cache-dir %t.d/c2
// RUN: %t.d/one | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: first
//
// RUN: %kairo --type-check-only %s %S/second.k
//
// kcc decides the root the same way: each `.k` on its command line.
// RUN: %if kcc %{ { %kcc %s %S/second.k -o %t.d/kboth 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG %}
// RUN: %if kcc %{ cd %t.d && %kcc -c %s %S/second.k && test -e %t.d/first.o && test -e %t.d/second.o %}
