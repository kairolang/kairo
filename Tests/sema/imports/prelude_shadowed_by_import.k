// The builtin prelude is consulted last: a name an import the user wrote
// brings shadows the builtin library's. ParseError and Copyable are both
// public builtin names; the imported ones bind here, with no ambiguity.

import user_errors::*

struct Tag { var v: i32 }
extend Tag impl Copyable { fn tag(const self) -> i32 { return self.v } }

fn pos_of(e: ParseError) -> i32 { return e.pos }

fn main() -> i32 {
    var t = Tag { v: 2 }
    return pos_of(ParseError { pos: 40 }) + t.tag()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -I %S/inputs/prelude_shadow --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: R016E
// CHECK-NOT: error
// RUN: rm -f %t.exe
// RUN: %kairo %s -I %S/inputs/prelude_shadow -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
