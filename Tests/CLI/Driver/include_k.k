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

// A .k the build does not hold is an error at the include, not C++ lexing.
// RUN: { %kairo -c %S/Inputs/include_k/missing.cc %S/Inputs/include_k/geo.k --cache-dir %t.d/miss 2>&1 || true; } | %FileCheck %s --check-prefix=MISSING
// MISSING: missing.cc:1:10: error [CL001E]: cannot include '{{.*}}not_built.k': it is not part of this build
// RUN: not %kairo -c %S/Inputs/include_k/missing.cc %S/Inputs/include_k/geo.k --cache-dir %t.d/miss > /dev/null 2>&1

// The interface is C++: a C translation unit cannot take it.
// RUN: { %kairo -c %S/Inputs/include_k/from_c.c %S/Inputs/include_k/geo.k --cache-dir %t.d/c 2>&1 || true; } | %FileCheck %s --check-prefix=FROMC --implicit-check-not=error
// FROMC: from_c.c:1:10: error [CL001E]: cannot include '{{.*}}geo.k': a Kairo file can only be included from C++ or Objective-C++

// Objective-C++ is C++ to the include: same interface, same tokens.
// RUN: %kairo -c %S/Inputs/include_k/objcxx.mm %S/Inputs/include_k/geo.k --cache-dir %t.d/mm
// RUN: test -s %t.d/mm/objcxx.o
