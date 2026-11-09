import lib::*

// The C++ default argument `= __kairo_default_put_text()` is written on
// the declaration, and clang builds that call where the declaration is, so
// the thunk's return type (`string`) must be Complete in every TU holding it.
// Here app's TU only names Sink and never string by value.
fn main() -> i32 {
    var s = Sink()
    return s.put(3)
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: incomplete return type
// RUN: %t.exe; test $? -eq 4
