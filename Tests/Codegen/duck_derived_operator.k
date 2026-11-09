// Inside a duck <T: type> body, `s + "::" + t` on strings and `m |= B` on an enum
// with a free `op |` were emitted as raw C++ `+` / `|=`, which the types do not have:
// Kairo derives them from `op +=` / `op |`. The dependent form tries C++'s operator and
// falls back to the derivation.

enum Mod derives u16 { None = 0, A = 1, B = 2 }
pub fn op | (a: Mod, b: Mod) -> Mod { return ((a as u16) | (b as u16)) as u16 as Mod; }
class Host derives Mixin<Host> {
    fn nm(self) -> string { return "x"; }
    var mods: Mod = Mod::None;
}
class <T: type> Mixin {
    inline fn dyn(self) -> *T { return unsafe (&self as *T); }
    pub fn go(self) -> i32 {
        var s = self.dyn()->nm() + "::" + self.dyn()->nm();
        self.dyn()->mods |= Mod::B;
        if (s == "x::x") && (self.dyn()->mods == Mod::B) { return 7 }
        return 0
    }
}
fn main() -> i32 { var h = Host(); return h.go() }

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: CL001E
// RUN: %t.exe; test $? -eq 7
