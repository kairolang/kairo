// std::move out of a field of self, a by-value parameter, a field and the
// pointee through a pointer, an array element and a vector element compiles
// to a C++ move of a move-only class: each moved value is destroyed once as a
// live resource, and its source once more as a moved-from shell.

import std
import std::io

var g_moves: i32 = 0
var g_live:  i32 = 0

class Res {
    pub var id: i32 = 0
    fn Res(self) {
        self.id = 0
    }

    fn Res(self, id: i32) {
        self.id = id
    }

    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
        g_moves += 1
    }

    fn op finally(self) {
        if self.id != 0 {
            g_live += 1
        }
    }
}

class Pair {
    pub var a: Res
    pub var b: Res
    fn Pair(self) {
        self.a = Res(1)
        self.b = Res(2)
    }

    fn take_a(self) -> Res {
        return std::move(self.a)
    }
}

fn by_param(r: Res) -> i32 {
    var x = std::move(r)
    return x.id
}

fn through(q: *Pair) -> i32 {
    var y = std::move(q->a)
    return y.id
}

fn pointee(q: *Res) -> i32 {
    var y = std::move(*q)
    return y.id
}

fn report(const what: string) {
    io::println(f"{what}: moves={g_moves} live={g_live}")
    g_moves = 0
    g_live  = 0
}

fn main() -> i32 {
    {
        var p = Pair()
        g_moves = 0
        var x = p.take_a()
        io::println(f"self.a={x.id}")
    }

    report("self field")
    {
        var r = Res(5)
        g_moves = 0
        var n = by_param(std::move(r))
        io::println(f"param={n}")
    }

    report("param")
    {
        var p = Pair()
        g_moves = 0
        var n = through(&p)
        io::println(f"p->a={n}")
    }

    report("p->a")
    {
        var r = Res(6)
        var n = pointee(&r)
        io::println(f"*p={n}")
    }

    report("*p")
    {
        var arr: [Res; 2]
        arr[0]  = Res(7)
        g_moves = 0
        var e = std::move(arr[0])
        io::println(f"array={e.id}")
    }

    report("array")
    {
        var v: [Res] = []
        v.push(Res(8))
        g_moves = 0
        var e = std::move(v[0])
        io::println(f"vector={e.id}")
    }

    report("vector")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: self.a=1
// OUT-NEXT: self field: moves=1 live=2
// OUT-NEXT: param=5
// OUT-NEXT: param: moves=2 live=1
// OUT-NEXT: p->a=1
// OUT-NEXT: p->a: moves=1 live=2
// OUT-NEXT: *p=6
// OUT-NEXT: *p: moves=1 live=1
// OUT-NEXT: array=7
// OUT-NEXT: array: moves=1 live=1
// OUT-NEXT: vector=8
// OUT-NEXT: vector: moves=1 live=1
