// The override returns clang accepts over a Kairo virtual stay legal
// (override_return_kairo_virtual.k has the rejected ones): a pointer
// to the same record or to a derived one, safe or unsafe on either side,
// through more than one base, through a `derives priv` base (every C++ base
// is public), and with less const than the base's.

class KB {
    var tag: i32 = 1
    virtual fn me(self) -> *KB { return &self }
    virtual fn raw(self) -> unsafe *KB { return unsafe &self }
    virtual fn mix(self) -> *KB { return &self }
    virtual fn view(self) -> *const KB { return &self }
    virtual fn same(self) -> i32 { return 1 }
}

class KM derives KB { }

class KD derives KM {
    override fn me(self) -> *KD { return &self }
    override fn raw(self) -> unsafe *KD { return unsafe &self }
    override fn mix(self) -> unsafe *KD { return unsafe &self }
    override fn view(self) -> *KD { return &self }
    override fn same(self) -> i32 { return 2 }
}

class KP derives priv KB {
    override fn me(self) -> *KP { return &self }
}

fn main() -> i32 {
    var d = KD()
    d.tag = 5
    var *b = d.me()
    if b->tag != 5 { return 1 }
    if d.same() != 2 { return 2 }
    var p = KP()
    if p.me()->tag != 1 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not="error ["
// RUN: rm -rf %t.d && %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
