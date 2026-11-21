// A caller whose own bounds promise an imported callee's bound is accepted
// in its generic body and runs: `T impl Copyable` meets std::copy's bound,
// and an interface deriving Copyable meets it too.

import std
import std::io

interface Dupe derives Copyable {
    fn tag(const self) -> i32
}

class Box impl Dupe {
    var v: i32

    fn Box(self, v: i32) {
        self.v = v
    }

    fn copy(const self) -> Box {
        return Box(self.v + 1)
    }

    fn tag(const self) -> i32 {
        return self.v
    }
}

fn <T impl Copyable> dup(const x: T) -> T {
    return std::copy(x)
}

fn <T impl Dupe> dup_tagged(const x: T) -> i32 {
    return std::copy(x).tag()
}

fn main() -> i32 {
    var a = dup(41)
    var b = dup_tagged(Box(1))
    var s = dup("hi")
    io::println(f"{a} {b} {s}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: error
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 41 2 hi
