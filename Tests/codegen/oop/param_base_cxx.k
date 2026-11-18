// The base a generic class derives through its type parameter may be an
// imported C++ class (c-cpp.mdx, Inheritance): one Kairo class hooks every
// action of a C++ hierarchy, where each action needed a class of its own.
// `Hosted<A>` overrides the protected virtual `begin` of the bound
// `act::Action`, calls the argument's own `begin` first (`A::begin(self,
// x)`: Doubler's refuses 100 and above, Adder inherits Action's), reads the
// bound's protected field, and is handed to C++ as an `act::Action&`, whose
// `run` dispatches back into the override. Each instance is built by its
// argument's default constructor and keeps the argument's public members.

ffi "c++" import "inputs/param_base_cxx.hh"

import std::io

class <A derives act::Action> Hosted derives A {
    pub var seen: i32 = 0
    override fn begin(self, x: i32) -> bool {
        if !A::begin(self, x) {
            return false
        }

        self.seen += self.scale
        return true
    }
}

fn main() -> i32 {
    var d = Hosted<act::Doubler>()
    var a = Hosted<act::Adder>()
    var p = Hosted<act::Action>()
    a.bias = 7
    io::println(f"doubler {d.run(21)} {d.run(100)} {d.run(-1)} seen {d.seen} runs {d.runs}")
    io::println(f"adder {a.run(1)} {act::drive(&a, 2)} seen {a.seen} runs {a.runs}")
    io::println(f"plain {act::drive(&p, 9)} seen {p.seen}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      doubler 42 -1 -1 seen 2 runs 3
// CHECK-NEXT: adder 8 9 seen 4 runs 2
// CHECK-NEXT: plain 9 seen 2
