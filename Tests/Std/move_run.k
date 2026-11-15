// std::move compiles to a real C++ move: a move-only class (one with no copy
// constructor, so a copy would not compile) is moved by exactly one move
// construction into `var b = std::move(a)`, the live resource is destroyed
// once and the moved-from shell once more. Passing std::move(x) on to a
// `@move` parameter adds no transfer. A COPY class has no move constructor,
// so std::move of one copies; both objects stay alive in C++.
// cxx::std::move from the C++ header is a different function and still
// works in the same file.

ffi "c++" import "utility"

import std
import std::io

var g_moves:      i32 = 0
var g_copies:     i32 = 0
var g_dtors:      i32 = 0
var g_live_dtors: i32 = 0

class Res {
    pub var id: i32
    fn Res(self, id: i32) {
        self.id = id
    }

    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
        g_moves += 1
    }

    fn op finally(self) {
        g_dtors += 1
        if self.id != 0 {
            g_live_dtors += 1
        }
    }
}

class Cp {
    pub var id: i32
    fn Cp(self, id: i32) {
        self.id = id
    }

    @copy fn Cp(self, const other: Self) {
        self.id = other.id
        g_copies += 1
    }

    fn op finally(self) {
        g_dtors += 1
        if self.id != 0 {
            g_live_dtors += 1
        }
    }
}

fn sink(@move r: Res) -> i32 {
    return r.id
}

fn report(const what: string) {
    io::println(
        f"{what}: moves={g_moves} copies={g_copies} dtors={g_dtors} live={g_live_dtors}",
    )

    g_moves      = 0
    g_copies     = 0
    g_dtors      = 0
    g_live_dtors = 0
}

fn main() -> i32 {
    {
        var a = Res(7)
        var b = std::move(a)
        io::println(f"b={b.id}")
    }

    report("local")
    {
        var a = Res(8)
        var n = sink(std::move(a))
        io::println(f"sink={n}")
    }

    report("into @move")
    {
        var a = Res(9)
        var b = std::move(a)
        a = Res(10)
        io::println(f"a={a.id} b={b.id}")
    }

    report("reassigned")
    {
        var c = Cp(5)
        var d = std::move(c)
        io::println(f"d={d.id}")
    }

    report("copy class")
    {
        var a = Res(11)
        var b = cxx::std::move(a)
        io::println(f"cxx b={b.id}")
    }

    report("cxx::std::move")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: b=7
// OUT-NEXT: local: moves=1 copies=0 dtors=2 live=1
// OUT-NEXT: sink=8
// OUT-NEXT: into @move: moves=1 copies=0 dtors=2 live=1
// OUT-NEXT: a=10 b=9
// OUT-NEXT: reassigned: moves=2 copies=0 dtors=4 live=2
// OUT-NEXT: d=5
// OUT-NEXT: copy class: moves=0 copies=1 dtors=2 live=2
// OUT-NEXT: cxx b=11
// OUT-NEXT: cxx::std::move: moves=1 copies=0 dtors=2 live=1
