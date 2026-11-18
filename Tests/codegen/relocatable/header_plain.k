// A header for a module with no `@relocatable` record carries no compiler
// guard: nothing in it depends on `trivial_abi`.
pub class Counter {
    pub var n: i32 = 0

    pub fn bump(self) -> i32 {
        self.n += 1
        return self.n
    }
}

pub fn twice(x: i32) -> i32 {
    return x * 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: %FileCheck %s --check-prefix=HDR < %t.d/h/header_plain.hh
// HDR:     #pragma once
// HDR-NOT: trivial_abi
// HDR-NOT: #error
// HDR:     class Counter {
// HDR-NOT: trivial_abi
// HDR-NOT: #error
