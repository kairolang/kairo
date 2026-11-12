// A Kairo class template bounded by an interface, `class <T impl
// Named> Holder`, was emitted as a bare `template<class T> class Holder`,
// so a C++ host could make a `Holder<Plain>` with a type that does not
// conform, and nothing said so unless a member calling the bound was used.
// The class head stays unconstrained (Compiler/Spec/Witnesses.md,
// CXXSpell::defers_bounds): clang checks a head clause wherever the
// template-id is named, and a CRTP base `Seven derives Mixin<Seven>` or a
// field `*Holder<Node>` inside Node names it over an incomplete argument,
// which clang then rejects. Each constructor of the template asserts the
// bound instead: its body is instantiated when a value is made, after the
// argument is complete. good.cc makes a Holder<Good> (5); bad.cc a
// Holder<Plain>, now a static assertion naming the bound.
// Codegen/oop/crtp_bounded_shapes.k keeps the CRTP and pointer shapes.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/bounded_class_template/good.cc -I %S/Inputs/bounded_class_template -o %t.d/good
// RUN: %t.d/good; test $? -eq 5
// RUN: { %kcc %S/Inputs/bounded_class_template/bad.cc -I %S/Inputs/bounded_class_template -o %t.d/bad 2>&1 || true; } | %FileCheck %s
// CHECK: holder.k:7:34: error [CL001E]: static assertion failed: 'Holder' requires 'T' to implement 'Named'
// CHECK: bad.cc:4:27: note [{{.*}}]: in instantiation of member function 'holder::Holder<Plain>::Holder' requested here
// CHECK: note [{{.*}}]: because 'Plain' does not satisfy 'Named_c'
// RUN: test ! -e %t.d/bad
