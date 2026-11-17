// A value converted by its own `@implicit op as` is that method's
// receiver: the conversion reads it where it is and transfers nothing, so
// a move-only source stays usable after the converted value is bound.

class View {
    pub var n: i32
    pub fn View(self, n: i32) { self.n = n }
}

class Owner {
    pub var n: i32
    pub fn Owner(self, n: i32) { self.n = n }
    @move pub fn Owner(self, other: Self) { self.n = other.n; other.n = -1 }
    @implicit pub fn op as (const self) -> View { return View(self.n) }
}

fn main() -> i32 {
    var o = Owner(7)
    var v: View = o
    return o.n + v.n - 14
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
