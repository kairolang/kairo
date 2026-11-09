// Ownership of `{K: V}` / `{T}`: every block goes back to the allocator in
// effect and every key and value is destroyed exactly once -- through
// growth (entries relocated by copy + destroy, Tracked not being trivially
// relocatable), erase (swap-remove and order-keeping), clear, copy, `=`,
// and the destructor. 100k inserts and erases cross mimalloc's small/large
// boundary many times over. A counting global allocator checks the bytes,
// Tracked's lifecycle checks the objects.
import builtin::base::alloc::*

static blocks: i64 = 0
static bytes: i64 = 0

class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { blocks += 1; bytes += size as i64; return System::alloc(size, align) }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { blocks -= 1; bytes -= size as i64; System::free(ptr, size, align) }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Counting>(ptr, o, n, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { blocks += 1; bytes += size as i64; return System::alloc_zeroed(size, align) }
}
@set_global_allocator(Counting)

static live: i64 = 0

/// A value with a destructor: live counts constructions minus destructions.
class Tracked {
    pub var v: i64
    fn Tracked(self) { self.v = 0; live += 1 }
    fn Tracked(self, v: i64) { self.v = v; live += 1 }
    @copy fn Tracked(self, const o: Tracked) { self.v = o.v; live += 1 }
    fn op finally(self) { live -= 1 }
}

/// A key with a destructor.
class Key impl Hash {
    pub var k: i64
    fn Key(self, k: i64) { self.k = k; live += 1 }
    @copy fn Key(self, const o: Key) { self.k = o.k; live += 1 }
    fn op finally(self) { live -= 1 }
    pub fn hash(const self) -> usize = to_usize(mix64(self.k as u64))
    pub fn op ==(const self, const other: Key) -> bool = self.k == other.k
}

fn churn() -> i32 {
    var m: {Key: Tracked}
    var i: i64 = 0
    while i < 100000 { m.insert(Key(i), Tracked(i * 3)); i += 1 }
    if m.size() != 100000 { return 1 }
    if live != 200000 { return 2 }                     // every temporary gone
    i = 0
    while i < 100000 { if !m.erase(Key(i)) { return 3 }; i += 2 }
    if (m.size() != 50000) || (live != 100000) { return 4 }
    i = 1
    while i < 1000 { if !m.erase_ordered(Key(i)) { return 5 }; i += 2 }
    if live != 2 * (50000 - 500) { return 6 }
    var c = m                                          // deep copy
    if live != 4 * (50000 - 500) { return 7 }
    c.clear()
    if live != 2 * (50000 - 500) { return 8 }
    var d: {Key: Tracked}
    d[Key(7)] = Tracked(7)
    d = m                                              // `=`: the old entry destroyed
    if live != 4 * (50000 - 500) { return 9 }

    var s: {Key}
    i = 0
    while i < 5000 { s.insert(Key(i)); i += 1 }
    var s2 = s
    s2.erase(Key(1))
    if (s.size() != 5000) || (s2.size() != 4999) { return 10 }
    return 0
}

fn main() -> i32 {
    var r = churn()
    if r != 0 { return r }
    if live != 0 { return 20 }                         // every key and value destroyed once
    if (blocks != 0) || (bytes != 0) { return 21 }     // every block freed
    return 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 100
