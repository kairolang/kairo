// A full specialization `fn <> f<A>(...)` is the C++ explicit specialization
// of its primary: a call of the primary at those arguments runs the
// specialization's body, whether the arguments are written or deduced and
// whichever order the two are declared in. A generic caller's instance at
// those arguments reaches it too.

fn <T> one() -> i32 { return 1 }
fn <> one<i32>() -> i32 { return 2 }

// Two specializations, one written above its primary.
fn <> two<u8>() -> i32 { return 3 }
fn <T> two() -> i32 { return 1 }
fn <> two<i64>() -> i32 { return 4 }

// Three, with a parameter: deduced at the call.
fn <T> three(x: T) -> i32 { return 1 }
fn <> three<i32>(x: i32) -> i32 { return x + 10 }
fn <> three<bool>(x: bool) -> i32 { return 20 }
fn <> three<*i32>(x: *i32) -> i32 { return 30 }

fn <T> via() -> i32 { return one<T>() }

fn main() -> i32 {
    if one<i32>() * 10 + one<u8>() != 21 { return 1 }
    if two<u8>() != 3 || two<i64>() != 4 || two<i16>() != 1 { return 2 }
    var v: i32 = 0
    if three(5) != 15 || three(true) != 20 || three(&v) != 30 || three(1.5) != 1 { return 3 }
    if via<i32>() != 2 || via<u8>() != 1 { return 4 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The C++ is the explicit specialization, declared after its primary.
// RUN: %kairo %s --print-ir 2>/dev/null | %FileCheck %s --check-prefix=IR
// IR: template{{ ?}}<class T> signed int two() noexcept;
// IR: template{{ ?}}<>{{.*}} signed int two<unsigned char>() noexcept;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
