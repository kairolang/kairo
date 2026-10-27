// A conforming method of a panicking interface requirement returns the
// requirement's result, whatever its own (smaller) set: the witness
// forwards `self->read(n)` as `Panic<i32, ReadError, Closed>` and its
// `requires` test names that exact member pointer type, so it is the
// override rule (PANIC.md §4.7) for conformers. Before, a conformer that
// does not panic returned plain `int` and every `return` failed in C++ ("no
// viable conversion from 'int' to Panic<...>"). Covered: a class with no
// panic at all and several returns, a class whose set is a strict nonempty
// subset, a method met through `extend X impl I` (the row is the
// extension's, the witness the class's own member), and a struct whose
// witness is in the extension itself. Each is called directly (the caller handles only the
// conformer's own set) and through the requirement's qualified form.
struct ReadError { var n: i32 }
struct Closed {}

interface Source {
    fn read(self, n: i32) panic(ReadError, Closed) -> i32
}

class Memory impl Source {
    fn read(self, n: i32) -> i32 {
        if n == 1 { return 10 }
        if n == 2 { return 20 }
        return 0
    }
}

class Strict impl Source {
    var base: i32
    fn Strict(self, base: i32) { self.base = base }
    fn read(self, n: i32) panic(ReadError) -> i32 {
        if n == 0 { panic ReadError { n: 7 } }
        return self.base + n
    }
}

class Late {
    fn read(self, n: i32) -> i32 { return n * 3 }
}
extend Late impl Source {}

struct Ext {}
extend Ext impl Source {
    fn read(self, n: i32) panic(Closed) -> i32 {
        if n < 0 { panic Closed {} }
        return n + 100
    }
}

fn via_req(m: Memory) -> i32 { return try Source::read(m, 2) catch => -1 }

fn main() -> i32 {
    var m = Memory()
    if m.read(1) != 10 { return 1 }
    if m.read(2) != 20 { return 2 }
    if m.read(9) != 0 { return 3 }
    var s = Strict(5)
    if (try s.read(1) catch e: ReadError => -1) != 6 { return 4 }
    if (try s.read(0) catch e: ReadError => e.n) != 7 { return 5 }
    var l = Late()
    if l.read(4) != 12 { return 6 }
    var x = Ext()
    if (try x.read(1) catch e: Closed => -1) != 101 { return 7 }
    if (try x.read(-1) catch e: Closed => -1) != -1 { return 8 }
    if via_req(m) != 20 { return 9 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
