// `priv` and `prot` are module-wide (classes.mdx, Visibility; decision
// 2026-10-26): every function in the class's file -- free ones included --
// sees its private members. AccessCheck allows it, and the emitted C++
// writes every Kairo member `public:` (C++ has no access level for "this
// file"), so it compiles AND runs. Before, Kairo accepted these and clang
// refused each one (CL001E "'secret' is a private member of ...").
//
// Each check returns its own code on failure; 0 is a pass.

class Vault {
    var secret: i32 = 7
    prot var shared: i32 = 11
    static count: i32 = 3
    priv fn peek(const self) -> i32 { return self.secret }
    prot fn guard(const self) -> i32 { return self.shared }
    fn Vault(self) { }
    priv fn Vault(self, s: i32) { self.secret = s }
    priv class Key { var k: i32 = 2 }
    fn total(const self) -> i32 { return self.secret + Self::count }
}

class <T> Cell {
    var item: T
    fn Cell(self, t: T) { self.item = t }
}

class Sealed derives priv Vault {
    fn Sealed(self) { }
}

fn main() -> i32 {
    var v = Vault()
    if v.secret != 7 { return 1 }               // a default-priv field
    var w = Vault(5)                            // a priv constructor
    if w.secret != 5 { return 2 }
    var p: *Vault = &w
    if p->secret != 5 { return 3 }              // through a pointer
    if v.peek() != 7 { return 4 }               // a priv method
    if v.guard() != 11 { return 5 }             // a prot method
    if v.shared != 11 { return 6 }              // a prot field
    if Vault::count != 3 { return 7 }           // a default-priv static
    if v.total() != 10 { return 8 }             // `Self::` inside the class
    var k = Vault::Key{}                        // a priv nested type
    if k.k != 2 { return 9 }
    var c = Cell<i32>(9)
    if c.item != 9 { return 10 }                // a generic class's priv field
    var s = Sealed()
    if s.secret != 7 { return 11 }              // through a priv base edge, in its file
    v.secret = 1
    if v.peek() != 1 { return 12 }              // written, not only read
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
