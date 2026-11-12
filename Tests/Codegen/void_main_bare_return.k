// `fn main()` with no result is emitted as `int main()`, where a bare
// `return;` is ill-formed (C886E "non-void function 'main' should return a
// value"). A `return` in it, and the early-return path an `eval for` leaves
// in it, are `return 0;`. Falling off the end was always fine.

import std::io

fn stop() -> bool { return true }

fn main() {
    eval for i in 0..3 {
        io::println(f"{i}")
        if i == 1 && stop() { return }
    }

    if stop() { return }
    io::println("unreached")
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: int main() noexcept {
// IR-NOT: return;
// IR: return 0;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 0
// RUN: %FileCheck %s --check-prefix=OUT < %t.out
// OUT:      0
// OUT-NEXT: 1
// OUT-NOT: {{.}}
