// NULLABLE.md G2: ::builtin::Nullable, the type `T?` lowers to, used from
// a C++ host (Inputs/nullable_host: widgets.k, nullable_main.cpp). Both
// constructors convert implicitly (`= ::builtin::null`, `= 5`), is_null()
// and `==` / `!=` test it, `__value()` reads the payload. A null nullable
// of a class holds no object (nothing is destroyed for it), a present one
// destroys its payload exactly once -- on replacement and at scope exit --
// and a Nullable of a move-only class is move-only (static_asserts in the
// host). Widget has no default constructor, so neither does the payload.
// widgets.k returns a `Widget?` built from a value and from `null`, so the
// host also sees what Kairo's `T?` lowers to. Widget is COPY (its move is
// its copy), so each temporary it is built through is a live Widget too.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/nullable_host/nullable_main.cpp -o %t.d/app 2>/dev/null
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      a null 1, b null 0, d null 1
// CHECK-NEXT: b == c 1, a == b 0, a == d 1, b != a 1, b == 5 1, a == null 1
// CHECK-NEXT: b value 5
// CHECK-NEXT: b null after reset 1
// CHECK-NEXT: widgets
// CHECK-NEXT:   ~Widget 7
// CHECK-NEXT: one holds 7, none null 1
// CHECK-NEXT: copy equal 1
// CHECK-NEXT:   ~Widget 7
// CHECK-NEXT:   ~Widget 8
// CHECK-NEXT:   ~Widget 8
// CHECK-NEXT: replaced
// CHECK-NEXT:   ~Widget 8
// CHECK-NEXT:   ~Widget 7
// CHECK-NEXT: from kairo
// CHECK-NEXT:   ~Widget 9
// CHECK-NEXT: boxed holds 9, nothing null 1
// CHECK-NEXT:   ~Widget 9
// CHECK-NEXT: uniq
// CHECK-NEXT: u null 0, u id 0, w id 3
// CHECK-NEXT: u reset 1
// CHECK-NEXT:   ~Uniq 3
// CHECK-NEXT: done
// CHECK-EMPTY:
