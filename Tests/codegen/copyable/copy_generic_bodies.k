// `.copy()` on a concrete COPY type is written anywhere: in a generic
// function's body, on a field of a generic class, in an imported file's
// generic code instantiated from here, and on `self` in a class with no
// `copy` of its own.

import inputs::copylib::*

var copies: i32 = 0

class Node {
    pub var n: i32

    pub fn Node(self, n: i32) {
        self.n = n
    }

    @copy pub fn Node(self, const other: Self) {
        self.n = other.n
        copies += 1
    }

    pub fn twin(const self) -> Node {
        return self.copy()
    }
}

fn <T> local(const x: T) -> i32 {
    var c = Node(2)
    return 5.copy() + c.copy().n
}

fn main() -> i32 {
    var t = Tagged<bool>(true)
    var n = Node(1).twin()
    if copies != 1 || n.n != 1 {
        return 1
    }

    if t.count() != 7 || seven(1.5) != 7 || local(true) != 7 || copies != 2 {
        return 2
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %overlay_builtins %t.lib base/copy.k=%S/inputs/copy.k
// RUN: { %kairo_overlay --builtins-dir=%t.lib/builtin %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo_overlay --builtins-dir=%t.lib/builtin %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
