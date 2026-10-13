// The derived `op =` built for a Windows target against the bundled MSVC
// sysroot, where libc++ takes its placement new from the MSVC runtime's
// headers rather than declaring its own. Each rebuilding row (a copy body,
// a move body, a generic class constrained per instance) must compile
// against it. Objects only: nothing here links or runs a Windows program.

class C {
    pub var v: i32
    pub fn C(self, v: i32) { self.v = v }
    @copy
    fn C(self, const other: Self) { self.v = other.v + 1 }
    fn op delete(self) { self.v = 0 }
}

class M {
    pub var v: i32
    pub fn M(self, v: i32) { self.v = v }
    @move
    fn M(self, other: Self) { self.v = other.v + 2 }
    fn op delete(self) { self.v = 0 }
}

class <X> Box {
    pub var v: X
    pub fn Box(self, v: X) { self.v = v }
    @copy
    fn Box(self, const other: Self) { self.v = other.v }
    fn op delete(self) { }
}

fn main() -> i32 {
    var a = C(1)
    var b = C(2)
    a = b
    var m = M(1)
    m = M(5)
    var x = Box<i32>(1)
    var y = Box<i32>(2)
    x = y
    return a.v + m.v + x.v
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: bundled-sysroot
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --target=x86_64-pc-windows-msvc --cache-dir %t.d
// RUN: test -f %t.d/derived_assign_msvc.o
