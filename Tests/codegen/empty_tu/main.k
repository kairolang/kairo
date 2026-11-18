import empty
import comments
import reexport

fn main() -> i32 { return 7 }

// --- lit wiring -----------------------------------------------------------
// A TU whose plan has nothing to define -- zero bytes, comments only, or only
// a `pub import` -- emits nothing: no preamble text (not even its banner), no
// object and no header. Emptiness is the plan's, not the bytes'.
//
// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: empty.k
// CXX-NOT: comments.k
// CXX-NOT: reexport.k
// CXX: CXX PREAMBLE {{.*}}empty_tu/main.k
// CXX-NOT: empty.k
// CXX-NOT: comments.k
// CXX-NOT: reexport.k

// RUN: rm -rf %t.h
// RUN: { %kairo %s --type-check-only --emit-headers %t.h 2>&1 || true; }
// RUN: test -z "$(find %t.h -name 'empty.*' -o -name 'comments.*' -o -name 'reexport.*' 2>/dev/null)"

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: test -z "$(find %t.d -name 'empty.o' -o -name 'comments.o' -o -name 'reexport.o')"
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7
