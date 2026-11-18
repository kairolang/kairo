// `case var v` of a payload that cannot be copied reads it in place,
// read-only, in both match forms: no copy, no move, and the binder is a
// reference to const in the C++.

var moves: i32 = 0

class Mv {
    pub var v: i32 = 0
    fn Mv(self, v: i32) { self.v = v }
    @move fn Mv(self, other: Self) {
        self.v = other.v
        moves += 1
    }
    fn get(const self) -> i32 { return self.v }
}

enum Slot {
    Full { m: Mv },
    Empty { },
}

fn stmt_form(const s: Slot) -> i32 {
    match s {
        case .Full(var m) { return m.get() }
        case .Empty() { return 0 }
    }
}

fn value_form(const s: Slot) -> i32 {
    return match s {
        case .Full(var m) => m.v
        case .Empty() => 0
    }
}

fn main() -> i32 {
    var s = Slot::Full{m: Mv(5)}
    moves = 0
    var n = stmt_form(s) + value_form(s)
    return if (n == 10 && moves == 0) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT:   error [
// CXX:       const{{ ?}}::{{.*}}Mv & m =
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
