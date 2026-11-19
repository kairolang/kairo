// A COPY type meets the Copyable lang item through a bound in every
// position, with no `.copy()` on a concrete type anywhere in the file: an
// extension's parameter-list bound, an extension's requires clause, a
// member's requires clause and a class's requires clause. Each uses its own
// type, so the witness each one needs is emitted for that bound alone. A
// pointer meets the Hash lang item through an extension bound the same way.
// A static member of such an extension, called by its qualified name, is
// the same: with the compiler-provided conformances, and with a local
// interface met through an extension impl and through the class's own,
// on a primitive and on `string` too. An extension's operator under the
// extension's requires clause, `s |= o`, is the same.

class <K> Slot {
    pub var k: K
    pub var n: i32

    pub fn Slot(self, k: K) {
        self.k = k
        self.n = 0
    }

    pub fn op []= (self, const i: i32, const v: K) requires K impl Copyable {
        self.k = v.copy()
        self.n = i
    }
}

extend <K impl Copyable> Slot<K> {
    fn put(self, const v: K) {
        self.k = v.copy()
        self.n += 1
    }
}

extend <K> Slot<K> requires K impl Copyable {
    fn put_twice(self, const v: K) {
        self.k = v.copy()
        self.n += 2
    }
}

extend <K impl Hash> Slot<K> {
    fn same_hash(const self, const o: K) -> bool {
        var a = Hasher(0); var b = Hasher(0); self.k.hash(&a); o.hash(&b); return a.finish() == b.finish()
    }
}

extend <K impl Copyable> Slot<K> {
    static fn dup(const v: K) -> K {
        return v.copy()
    }
}

extend <K impl Hash> Slot<K> {
    static fn hash_of(const v: K) -> usize {
        var s = Hasher(0); v.hash(&s); return s.finish() as usize
    }
}

interface Zero {
    fn zero() -> Self
}

class Ext {
    pub var n: i32

    pub fn Ext(self) {
        self.n = 2
    }
}

extend Ext impl Zero {
    static fn zero() -> Ext {
        return Ext()
    }
}

class Own impl Zero {
    pub var n: i32

    pub fn Own(self) {
        self.n = 3
    }

    pub static fn zero() -> Own {
        return Own()
    }
}

extend i64 impl Zero {
    static fn zero() -> i64 { return 4 }
}

extend string impl Zero {
    static fn zero() -> string { return "zz" }
}

extend <K> Slot<K> requires K impl Copyable {
    fn op |= (self, const o: Self) {
        self.k = o.k.copy()
        self.n += o.n
    }
}

extend <K impl Zero> Slot<K> {
    static fn make() -> K {
        return K::zero()
    }
}

class <K> Kept requires K impl Copyable {
    pub var k: K

    pub fn Kept(self, const k: K) {
        self.k = k.copy()
    }
}

var cell: i32 = 0

fn main() -> i32 {
    var a = Slot<u64>(1)
    a.put(5)
    if a.k != 5 || a.n != 1 {
        return 1
    }

    var b = Slot<string>("a")
    b.put_twice("bcd")
    if b.k.size() != 3 || b.n != 2 {
        return 2
    }

    var c = Slot<i16>(1)
    c[4] = 9
    if c.k != 9 || c.n != 4 {
        return 3
    }

    var d = Kept<u8>(7)
    if d.k != 7 {
        return 4
    }

    var e = Slot<unsafe *i32>(unsafe &cell)
    if !e.same_hash(unsafe &cell) {
        return 5
    }

    if Slot<i32>::dup(6) != 6 || Slot<unsafe *u8>::hash_of(&null) != Slot<unsafe *u8>::hash_of(&null) {
        return 6
    }

    if Slot<Ext>::make().n != 2 || Slot<Own>::make().n != 3 {
        return 7
    }

    if Slot<i64>::make() != 4 || Slot<string>::make().size() != 2 {
        return 8
    }

    var s = Slot<u32>(1)
    var o = Slot<u32>(6)
    s |= o
    if s.k != 6 || s.n != 0 {
        return 9
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
