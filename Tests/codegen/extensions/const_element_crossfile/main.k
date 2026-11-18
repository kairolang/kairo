// The extension members of an imported generic type, on both element forms
// and through a generic function of each file; a bounded extension of the
// imported file, with the conformance declared here.

import std::io
import self::view::*

struct Tag { var id: i32 }

// The conformance is this file's: view.k's bounded extension is used here
// on a `View<const Tag>` only, never on a `View<Tag>`.
extend Tag impl Same {
    fn same(const self, const o: Tag) -> bool { return self.id == o.id }
}

fn <U> here(v: View<const U>) -> usize { return v.size() + measure(v) }

fn main() -> i32 {
    var k: i32 = 5
    var a = View<i32>(&k, 2)
    var c = View<const i32>(const &k, 2)
    a.set0(6)
    io::println(f"{a.both()} {c.both()} {measure(c)} {here(c)} {*c.first()}")
    var t = Tag { id: 3 }
    var ct = View<const Tag>(const &t, 1)
    io::println(f"{ct.has(Tag { id: 3 })} {ct.has(Tag { id: 4 })} {ct == ct} {alike(ct, ct)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: warning
// BUILD-NOT: error
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 4 4 4 6 6
// OUT-NEXT: true false true true
