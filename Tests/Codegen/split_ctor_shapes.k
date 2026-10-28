// Run-time constructors split for const fields (CODEGEN.md §6), beside the
// shapes that once crashed or were refused around them: a class with a
// static field and an `@inout` method next to its split constructor (the
// null _ci_fn crash in EmitIR::_slot_type, 2026-10-24), a const field whose
// type has a const field itself (its one write constructs it, so it is no
// SC071E assignment), a generic class's, and fields the constructor leaves
// alone, which read 0.

pub class Counter {
    pub static made: i32 = 0
    pub const id: i32
    pub var n: i32 = 0

    pub fn Counter(self, id: i32) {
        self.id = id;
        Counter::made += 1;
    }

    pub fn bump(self, @inout k: i32) -> i32 {
        k += 1;
        self.n += k;
        return self.n;
    }
}

class Key {
    pub const k: i32
    fn Key(self, k: i32) { self.k = k }
}

class Entry {
    pub const key: Key
    pub var hits: i32
    pub var w: f64
    fn Entry(self, k: i32) {
        var sq = k * k
        self.key = Key(sq)
        self.hits += 1
    }
}

class <T> Holder {
    pub const v: T
    pub var tag: u8
    fn Holder(self, v: T) { self.v = v }
}

fn main() -> i32 {
    var c = Counter(4)
    var k = 1
    var r = c.bump(&k)                      // 2
    r += c.id * 10 + Counter::made * 100    // 142
    var e = Entry(3)
    r += e.key.k + e.hits                   // 152
    if e.w != 0.0 { r += 1000 }
    var h = Holder<i64>(7)
    r += (h.v as i32) + (h.tag as i32)      // 159
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 159
