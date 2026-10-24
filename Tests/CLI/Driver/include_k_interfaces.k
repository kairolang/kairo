// What crosses `#include "foo.k"` (Interop/Clang/KairoInclude.k) beyond
// free functions, and where the include is turned away. include_k.k covers
// the basic path and its errors.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// A struct by value and a class with a constructor, destructor and method:
// 3 + 4, then hits 2 and 2 + 3. The destructor runs at the C++ scope end.
// RUN: %kairo %S/Inputs/include_k/use_shapes.cc %S/Inputs/include_k/shapes.k -o %t.d/shapes --cache-dir %t.d/o1
// RUN: %t.d/shapes > %t.d/shapes.out; test $? -eq 14
// RUN: %FileCheck %s --check-prefix=SHAPES --input-file=%t.d/shapes.out
// SHAPES:      Tracer()
// SHAPES-NEXT: ~Tracer()

// geo.k is not on the command line: twice.k imports it, which makes it part
// of the build, so the .cc can include it. 4 + 2. (Including twice.k as well
// is two Kairo files in one TU, which M2 makes work.) From %t.d: lit's cwd
// holds both Output/ and output.k, which the import scan rejects as a case
// clash.
// RUN: cd %t.d && %kairo %S/Inputs/include_k/use_twice.cc %S/Inputs/include_k/twice.k -o %t.d/twice --cache-dir %t.d/o2
// RUN: %t.d/twice; test $? -eq 6

// A user copy constructor makes the derived assignment rebuild in place,
// which needs <new>: an included interface cannot bring a system header
// yet. M2 lifts this; turn the check into a run then.
// RUN: { %kairo -c %S/Inputs/include_k/use_boxed.cc %S/Inputs/include_k/boxed.k --cache-dir %t.d/o3 2>&1 || true; } | %FileCheck %s --check-prefix=NEW
// NEW: use_boxed.cc:1:10: error [CL001E]: cannot include '{{.*}}boxed.k': its interface needs <new>, and an included Kairo file cannot bring system headers yet

// Objective-C is C to the include. The refusal is the only error: what
// stands in for the file must not parse as C into more of them.
// RUN: { %kairo -c %S/Inputs/include_k/objc.m %S/Inputs/include_k/geo.k --cache-dir %t.d/o4 2>&1 || true; } | %FileCheck %s --check-prefix=OBJC --implicit-check-not=error
// OBJC: objc.m:1:10: error [CL001E]: cannot include '{{.*}}geo.k': a Kairo file can only be included from C++ or Objective-C++
