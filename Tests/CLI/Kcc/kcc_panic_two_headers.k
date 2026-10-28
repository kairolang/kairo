// Two Kairo headers (--emit-headers) in one C++ TU, both exposing the same
// panic result Panic<i32, Shared> (Inputs/panic_headers: errs.k, left.k,
// right.k, both.k -- the entry that imports them -- and host.cc). Each header declares its function returning the
// result ([[nodiscard]]), includes the error type's header (the result's
// elements must be complete where it is named), writes Shared's type-id
// specialization under one guard, and declares the instance
// `extern template`; the explicit instantiation is in exactly one object
// (the plan's one `home`). The host sees one type, the tags Kairo wrote
// are Shared's id in both, and value_or_throw / what() work through the
// headers as through a kcc include.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc -Xkairo --emit-headers=%t.d/h %S/Inputs/panic_headers/both.k %S/Inputs/panic_headers/host.cc -I %t.d/h -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      one type 1 tag is id 1 same tag 1
// CHECK-NEXT: code 2 what: shared failure [Shared at {{.*}}right.k:4:16]
// CHECK-NEXT: values 2 3
// CHECK-EMPTY:
//
// RUN: cat %t.d/h/left.hh | %FileCheck %s --check-prefix=LEFT
// LEFT:      #include "errs.hh"
// LEFT:      #ifndef __KAIRO_TID_[[KEY:[0-9a-f]+]]
// LEFT:      template<> struct __kairo_tid<::errs::Shared> {
// LEFT:      {{\[\[}}nodiscard]]::builtin::types::Panic<signed int,::errs::Shared> left(signed int k) noexcept;
// LEFT:      extern template struct::builtin::types::Panic<signed int,::errs::Shared>;
// RUN: cat %t.d/h/right.hh | %FileCheck %s --check-prefix=RIGHT
// RIGHT:      #include "errs.hh"
// RIGHT:      #ifndef __KAIRO_TID_{{[0-9a-f]+}}
// RIGHT:      {{\[\[}}nodiscard]]::builtin::types::Panic<signed int,::errs::Shared> right(signed int k) noexcept;
// RIGHT:      extern template struct::builtin::types::Panic<signed int,::errs::Shared>;
//
// RUN: %kairo %S/Inputs/panic_headers/both.k --print-emit-plan -c > %t.d/plan.txt 2>&1
// RUN: test "$(grep -c 'Panic<signed int, ::errs::Shared>.* home$' %t.d/plan.txt)" = 1
