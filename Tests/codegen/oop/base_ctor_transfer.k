// A derived class's own `@copy` / `@move` constructor initializes its base
// with the base's transfer constructor, `Base::Base(self, other)`: the
// source binds the base's `const Base&` / `Base&&` by derived-to-base
// conversion and only the base part is transferred
// (OverloadResolution::_transfer_upcast). And a base that declares only a
// deleted `@copy` has no implicit default constructor -- in Kairo as in
// C++ -- so it declares `fn X(self) = default` to stay derivable.
//
// Each check returns its own code on failure; 0 is a pass.

class Counted {
    pub var v: i32
    pub var copies: i32 = 0
    fn Counted(self, v: i32) { self.v = v }
    @copy
    fn Counted(self, const other: Self) {
        self.v = other.v
        self.copies = other.copies + 1
    }
}

class Tagged derives Counted {
    pub var tag: i32
    fn Tagged(self, v: i32, tag: i32) {
        Counted::Counted(self, v)
        self.tag = tag
    }
    @copy
    fn Tagged(self, const other: Self) {
        Counted::Counted(self, other)
        self.tag = other.tag + 10
    }
}

class Owned {
    pub var n: i32
    fn Owned(self, n: i32) { self.n = n }
    @move
    fn Owned(self, other: Self) {
        self.n = other.n
        other.n = 0
    }
}

class Wrapper derives Owned {
    fn Wrapper(self, n: i32) { Owned::Owned(self, n) }
    @move
    fn Wrapper(self, other: Self) { Owned::Owned(self, other) }
}

class NoCopy {
    pub var n: i32 = 4
    fn NoCopy(self) = default
    @copy
    fn NoCopy(self, const other: Self) = delete
}

class Kid derives NoCopy {
    pub var m: i32 = 5
}

fn main() -> i32 {
    var t = Tagged(3, 1)
    var u = t
    if (u.v != 3) || (u.copies != 1) || (u.tag != 11) { return 1 }   // the base copied once
    var w = Wrapper(9)
    var x = w
    if x.n != 9 { return 2 }
    var k = Kid()
    if (k.n != 4) || (k.m != 5) { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
