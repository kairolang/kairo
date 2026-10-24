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
// copy in the other. The second twice.k is include-once. The modules on the
// command line here, through one root (many.k) below.
// RUN: cd %t.d && %kairo %S/Inputs/include_k/use_many.cc %S/Inputs/include_k/twice.k %S/Inputs/include_k/moved.k -o %t.d/many --cache-dir %t.d/o5
// RUN: %t.d/many; test $? -eq 14
// RUN: cd %t.d && %kairo %S/Inputs/include_k/use_many_rev.cc %S/Inputs/include_k/many.k -o %t.d/many_rev --cache-dir %t.d/o6
// RUN: %t.d/many_rev > %t.d/many_rev.out; test $? -eq 15
// RUN: %FileCheck %s --check-prefix=MANY --input-file=%t.d/many_rev.out
// MANY:      Tracer()
// MANY-NEXT: ~Tracer()
// MANY-NEXT: greet hi 6

// Two C++ TUs including the same modules: what one put in its TU must not
// keep them out of the next. 6 + 2 + 1.
// RUN: cd %t.d && %kairo %S/Inputs/include_k/use_main.cc %S/Inputs/include_k/use_side.cc %S/Inputs/include_k/many.k -o %t.d/two_tus --cache-dir %t.d/o7
// RUN: %t.d/two_tus; test $? -eq 9

// Templates and inline functions: the host compiles them itself, so the
// stream carries their bodies (EmitPlan::include_bodies) -- Box<long> and
// first<short> are instances no Kairo code asked for, and sq has no
// out-of-line copy anywhere. 9 + 1 + 7 + (5 + 1).
// RUN: %kairo %S/Inputs/include_k/use_tmpl.cc %S/Inputs/include_k/tmpl.k -o %t.d/tmpl --cache-dir %t.d/o8
// RUN: %t.d/tmpl; test $? -eq 23

// The module's own ffi headers, which its interface and inline bodies name:
// entered ahead of the stream by the paths they resolved to, so the .cc
// needs no -I for them, and the `ffi "c"` one inside extern "C". 5 + 6.
// RUN: %kairo %S/Inputs/include_k/use_ffi.cc %S/Inputs/include_k/ffi/ffiuse.k -o %t.d/ffi --cache-dir %t.d/o9
// RUN: %t.d/ffi; test $? -eq 11

// clang's notes point at the name as written in the .k: the declaration's
// name token holds the name's own bytes (TokenSink::_claim).
// RUN: { %kairo -c %S/Inputs/include_k/typo.cc %S/Inputs/include_k/shapes.k --cache-dir %t.d/o10 2>&1 || true; } | %FileCheck %s --check-prefix=TYPO
// TYPO: typo.cc:4:13: error [CL001E]: no type named 'Tracr' in namespace 'shapes'; did you mean 'Tracer'?
// TYPO: shapes.k:12:11: note [I900N]: 'Tracer' declared here
// TYPO: typo.cc:5:20: error [CL001E]: no member named 'manhatan' in namespace 'shapes'; did you mean 'manhattan'?
// TYPO: shapes.k:8:8: note [I900N]: 'manhattan' declared here

// Only the pub interface crosses (EmitPlan Include mode): a priv or
// internal decl reaches the C++ TU only when an inline or template body
// names it, as twice_secret names secret. open's helpers stay in privy.o.
// 0 + (1 + 1) + 9.
// RUN: %kairo %S/Inputs/include_k/use_privy.cc %S/Inputs/include_k/privy.k -o %t.d/privy --cache-dir %t.d/o11
// RUN: %t.d/privy; test $? -eq 11
// RUN: { %kairo -c %S/Inputs/include_k/peek_privy.cc %S/Inputs/include_k/privy.k --cache-dir %t.d/o12 2>&1 || true; } | %FileCheck %s --check-prefix=PRIV
// PRIV: peek_privy.cc:3:28: error [CL001E]: no member named 'hidden' in namespace 'privy'

// Objective-C is C to the include. The refusal is the only error: what
// stands in for the file must not parse as C into more of them.
// RUN: { %kairo -c %S/Inputs/include_k/objc.m %S/Inputs/include_k/geo.k --cache-dir %t.d/o4 2>&1 || true; } | %FileCheck %s --check-prefix=OBJC --implicit-check-not=error
// OBJC: objc.m:1:10: error [CL001E]: cannot include '{{.*}}geo.k': a Kairo file can only be included from C++ or Objective-C++
