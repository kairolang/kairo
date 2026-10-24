// `#include "foo.k"` in a C++ input (Interop/Clang/KairoInclude.k): clang's
// preprocessor enters the .k, and instead of lexing Kairo source as C++ it
// takes foo.k's interface as tokens, emitted by Kairo from the analysed
// module. The .k is a Kairo file of the same build -- here given on the
// command line -- so its object is the build's own, and the link joins the
// two. A second include of the same file is a no-op (include-once).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// A .cc calls a Kairo function through the include, and runs: 2 + 7.
// RUN: %kairo %S/Inputs/include_k/main.cc %S/Inputs/include_k/geo.k -o %t.d/app --cache-dir %t.d/obj
// RUN: %t.d/app; test $? -eq 9

// -fsyntax-only and type checking on the .cc take the tokens too: a C++
// input runs the Kairo ones through sema whatever the action stops at.
// RUN: %kairo --syntax-only %S/Inputs/include_k/main.cc %S/Inputs/include_k/geo.k 2>&1 | %FileCheck %s --check-prefix=SYNTAX --allow-empty
// RUN: %kairo --type-check-only %S/Inputs/include_k/main.cc %S/Inputs/include_k/geo.k 2>&1 | %FileCheck %s --check-prefix=SYNTAX --allow-empty
// SYNTAX-NOT: error

// -E prints the stream as C++ that compiles on its own: the preprocessed
// .ii, with geo.k beside it only for its object, builds the same program.
// RUN: %kairo --preprocess %S/Inputs/include_k/main.cc %S/Inputs/include_k/geo.k > %t.d/main.ii
// RUN: %FileCheck %s --check-prefix=PP --input-file=%t.d/main.ii
// PP: namespace geo {
// PP-NOT: static_asserttrue
// RUN: %kairo %t.d/main.ii %S/Inputs/include_k/geo.k -o %t.d/app_ii --cache-dir %t.d/o_ii
// RUN: %t.d/app_ii; test $? -eq 9

// A .k no command-line word names is part of the build all the same: the
// driver finds it in the .cc (KairoIncludeScan), builds it, and links its
// object. Here not_built.k, beside an unrelated geo.k.
// RUN: %kairo -c %S/Inputs/include_k/missing.cc %S/Inputs/include_k/geo.k --cache-dir %t.d/miss
// RUN: test -s %t.d/miss/missing.o && test -s %t.d/miss/not_built.o

// Through a project header found by -I, with no .k on the command line at
// all: 2 + 10. Under -c -o, -o is the .cc's object; deep.o goes to the
// cache dir.
// RUN: %kairo %S/Inputs/include_k/nested.cc --cxx-include %S/Inputs/include_k/inc -o %t.d/nested --cache-dir %t.d/nest
// RUN: %t.d/nested; test $? -eq 12
// RUN: %kairo -c %S/Inputs/include_k/nested.cc --cxx-include %S/Inputs/include_k/inc -o %t.d/nested.o --cache-dir %t.d/nest_c
// RUN: test -s %t.d/nested.o && test -s %t.d/nest_c/deep.o
// The same through -I: one flag is the C++ include path and the .k search
// dir, so deep.k is found by the include AND is module `deep` of that dir
// (its path relative to it), the namespace nested.cc calls into.
// RUN: %kairo %S/Inputs/include_k/nested.cc -I %S/Inputs/include_k/inc -o %t.d/nested_i --cache-dir %t.d/nest_i
// RUN: %t.d/nested_i; test $? -eq 12

// twin.cc includes twin.k: the .cc's object keeps its name (twin.o), the
// Kairo one takes twin.k.o. Named and discovered alike. 5 * 3.
// RUN: %kairo %S/Inputs/include_k/twin.cc %S/Inputs/include_k/twin.k -o %t.d/twin --cache-dir %t.d/twin_o
// RUN: %t.d/twin; test $? -eq 15
// RUN: test -s %t.d/twin_o/twin.o && test -s %t.d/twin_o/twin.k.o
// RUN: %kairo %S/Inputs/include_k/twin.cc -o %t.d/twin2 --cache-dir %t.d/twin_o2
// RUN: %t.d/twin2; test $? -eq 15

// An include spelled through a macro is past what a scan sees: the .k is
// not in the build, and the include says so instead of lexing it as C++.
// RUN: { %kairo -c %S/Inputs/include_k/macro.cc --cache-dir %t.d/macro 2>&1 || true; } | %FileCheck %s --check-prefix=MACRO
// MACRO: macro.cc:2:10: error [CL001E]: cannot include '{{.*}}geo.k': it is not part of this build
// RUN: not %kairo -c %S/Inputs/include_k/macro.cc --cache-dir %t.d/macro > /dev/null 2>&1

// The interface is C++: a C translation unit cannot take it.
// RUN: { %kairo -c %S/Inputs/include_k/from_c.c %S/Inputs/include_k/geo.k --cache-dir %t.d/c 2>&1 || true; } | %FileCheck %s --check-prefix=FROMC --implicit-check-not=error
// FROMC: from_c.c:1:10: error [CL001E]: cannot include '{{.*}}geo.k': a Kairo file can only be included from C++ or Objective-C++

// Objective-C++ is C++ to the include: same interface, same tokens.
// RUN: %kairo -c %S/Inputs/include_k/objcxx.mm %S/Inputs/include_k/geo.k --cache-dir %t.d/mm
// RUN: test -s %t.d/mm/objcxx.o
