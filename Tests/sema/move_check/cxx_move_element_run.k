// An element handed off with cxx::std::move leaves the vector; assigning
// the vector again makes it usable.

ffi "c++" import "utility"

import std
import std::io

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) {
        self.id = id
    }

    @move fn Tok(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
}

fn eat(t: Tok) -> i32 {
    return t.id
}

fn main() -> i32 {
    var v:    [Tok] = [Tok(7), Tok(8)]
    var first       = cxx::std::move(v[0])
    v = [Tok(9)]
    var r = eat(cxx::std::move(v[0]))
    v = [Tok(10), Tok(11)]
    io::println(f"{first.id} {r} {v[1].id}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: 7 9 11
