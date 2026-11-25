// An imported overload set that only SFINAE splits, called with a
// `<T: type>` argument: which template holds is each instance's
// question, so the call is spelled by the set's C++ name and clang picks
// per instance. Under a duck parameter the instance may pick a Kairo
// function that panics, so the call is wrapped as a duck member call is.

ffi "c++" import "duck_dependent_set.h"

fn <T: type> classify(x: T) -> i32 { return kind(x) }

fn main() -> i32 {
    if classify(3) != 1 { return 1 }
    if classify(2.5) != 2 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR: return( ::__kairo_nopanic(), ::kind(static_cast<T &&>(x)));

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe
