// A class that derives its type parameter, used from another file than the
// one that declares it and its bound: the argument is this file's class.
// Member lookup through `Hooked<Local>` (the bound's overloads beside the
// mixin's, the argument's own member), the conversions to `*Local` and
// `*Base`, the override the mixin stacks on the argument's, and a second
// mixin layer all read the base off the instance, with no bound of this
// file to ask.

import self::lib::*
import std::io

class Local derives Base {
    pub var extra: i32 = 11
    pub fn Local(self) { self.n = 5 }
    pub override fn begin(self) -> i32 { return 10 }
    pub fn only_local(self) -> i32 { return self.extra }
}

fn main() -> i32 {
    var h = Hooked<Local>()
    var hh = Hooked<Hooked<Local>>()
    var l: *Local = &h
    io::println(f"{h.begin()} {h.both()} {h.plain()} {h.plain(2)} {h.plain(2, 3)} {h.only_local()} {l->only_local()}")
    io::println(f"{through(&h)} {through(&hh)} {hh.only_local()} {hh.n}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --match-full-lines < %t.out
// CHECK:      110 11 5 7 5 11 11
// CHECK-NEXT: 110 210 11 5
