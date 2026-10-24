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
// of the build, so the .cc can include it. 4 + 2. From %t.d: lit's cwd
// holds both Output/ and output.k, which the import scan rejects as a case
// clash.
// RUN: cd %t.d && %kairo %S/Inputs/include_k/use_twice.cc %S/Inputs/include_k/twice.k -o %t.d/twice --cache-dir %t.d/o2
// RUN: %t.d/twice; test $? -eq 6

// A user copy constructor makes the derived assignment rebuild in place,
// so the interface needs <new>. A token stream cannot carry an #include:
// the hook enters a buffer that includes <new>, then boxed.k again for the
// tokens. Boxed() sets v to 1.
// RUN: %kairo %S/Inputs/include_k/use_boxed.cc %S/Inputs/include_k/boxed.k -o %t.d/boxed --cache-dir %t.d/o3
// RUN: %t.d/boxed; test $? -eq 1

// Several Kairo files in one C++ TU. Each stream declares everything its
// module reaches, so geo is in both geo.k's and twice.k's, shapes::Point in
// both shapes.k's and moved.k's, and the lowering helpers and std::io in
// all of them: a later include leaves out what an earlier one put in the
// TU. Both orders, so the own copy is the skipped one in one and the foreign
// copy in the other. The second twice.k is include-once. many.k imports the
// lot: two Kairo files on one command line do not build yet.
// RUN: cd %t.d && %kairo %S/Inputs/include_k/use_many.cc %S/Inputs/include_k/many.k -o %t.d/many --cache-dir %t.d/o5
// RUN: %t.d/many; test $? -eq 14
// RUN: cd %t.d && %kairo %S/Inputs/include_k/use_many_rev.cc %S/Inputs/include_k/many.k -o %t.d/many_rev --cache-dir %t.d/o6
// RUN: %t.d/many_rev > %t.d/many_rev.out; test $? -eq 15
// RUN: %FileCheck %s --check-prefix=MANY --input-file=%t.d/many_rev.out
// MANY:      Tracer()
// MANY-NEXT: ~Tracer()
// MANY-NEXT: greet hi 6

// Objective-C is C to the include. The refusal is the only error: what
// stands in for the file must not parse as C into more of them.
// RUN: { %kairo -c %S/Inputs/include_k/objc.m %S/Inputs/include_k/geo.k --cache-dir %t.d/o4 2>&1 || true; } | %FileCheck %s --check-prefix=OBJC --implicit-check-not=error
// OBJC: objc.m:1:10: error [CL001E]: cannot include '{{.*}}geo.k': a Kairo file can only be included from C++ or Objective-C++
