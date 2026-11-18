// `[T]` owns its elements and its storage: every element constructed is
// destroyed exactly once, a copy is deep, growth relocates (a MOVE element
// is moved, never copied), and when the vectors are gone every block the
// global allocator handed out is back. Counted with a global allocator that
// forwards to System and keeps the live block and byte counts.

import std::mem::*

static live_blocks: i64 = 0
static live_bytes: i64 = 0

class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        live_blocks += 1; live_bytes += size as i64
        return System::alloc(size, align)
    }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        live_blocks -= 1; live_bytes -= size as i64
        System::free(ptr, size, align)
    }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool {
        if !System::resize(ptr, o, n, align) { return false }
        live_bytes += (n as i64) - (o as i64)
        return true
    }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        var unsafe *q = System::realloc(ptr, o, n, align)
        if q != &null { live_bytes += (n as i64) - (o as i64) }
        return q
    }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        live_blocks += 1; live_bytes += size as i64
        return System::alloc_zeroed(size, align)
    }
}

@set_global_allocator(Counting)

// --- a COPY element that counts ----------------------------------------------

static made: i64 = 0
static copied: i64 = 0
static dropped: i64 = 0

class Cp {
    var v: i32
    fn Cp(self) { self.v = 0; made += 1 }
    fn Cp(self, v: i32) { self.v = v; made += 1 }
    @copy fn Cp(self, const other: Self) { self.v = other.v; copied += 1 }
    fn op finally(self) { dropped += 1 }
}

// --- a MOVE element: a move empties the source --------------------------------

static mv_made: i64 = 0
static mv_moves: i64 = 0
static mv_live_drops: i64 = 0

class Mv {
    var v: i32
    var live: bool
    fn Mv(self, v: i32) { self.v = v; self.live = true; mv_made += 1 }
    @move fn Mv(self, other: Self) {
        self.v = other.v
        self.live = other.live
        other.live = false
        mv_moves += 1
    }
    fn op finally(self) { if self.live { mv_live_drops += 1 } }
}

fn cp_vectors() -> i32 {
    {
        var a: [Cp]
        a.reserve(8)
        var i: i32 = 0
        while i < 8 { a.emplace_back(i); i += 1 }    // no growth: no transfers
        if (made != 8) || (copied != 0) { return 1 }
        var b = a                                       // deep copy: 8 copies
        if copied != 8 { return 2 }
        b[0].v = 100
        if a[0].v != 0 { return 3 }
        a.pop_back()                                    // one drop
        if dropped != 1 { return 4 }
        unsafe { a.erase(a.begin() + 1, a.begin() + 3) }
        if (a.size() != 5) || (a[1].v != 3) { return 5 }
        a.clear()
        b.resize(3)
    }
    // every Cp that came into being was destroyed once
    if made + copied != dropped { return 6 }
    return 0
}

fn mv_vectors() -> i32 {
    {
        var a: [Mv]
        var i: i32 = 0
        while i < 100 {
            var m = Mv(i)
            a.push_back(m)                            // moved in: m is empty
            i += 1
        }
        a.emplace_back(100)
        a.insert(a.begin(), Mv(-1))
        unsafe { a.erase(a.begin() + 50) }
        if (a.size() != 101) || (a[0].v != -1) || (a[50].v != 50) || (a[100].v != 100) { return 1 }
        for *m in a { if !m->live { return 2 } }
        a.pop_back()
        unsafe { a.erase(a.begin() + 10, a.end()) }
    }
    // 102 Mvs were made; each live one was destroyed exactly once, however
    // many times growth, insert and erase moved it
    if mv_made != 102 { return 3 }
    if mv_live_drops != 102 { return 4 }
    if mv_moves == 0 { return 5 }
    return 0
}

fn strings() -> i32 {
    var s: [string] = ["a", "bc"]
    var t = "def"
    s.push_back(t)
    s.push_back("gh")
    var u = s
    u[0] = "zz"
    if s[0].length() != 1 { return 1 }
    if u[0].length() != 2 { return 2 }
    var total: usize = 0
    for x in s { total += x.length() }
    if total != 1 + 2 + 3 + 2 { return 3 }
    s.insert(s.begin(), "x")
    unsafe { s.erase(s.begin() + 2) }
    if (s.size() != 4) || (s[1].length() != 1) || (s[2].length() != 3) { return 4 }
    return 0
}

fn nested() -> i32 {
    var g: [[i32]]
    var r: i32 = 0
    while r < 50 {
        var row: [i32]
        var c: i32 = 0
        while c <= r { row.push_back(c); c += 1 }
        g.push_back(row)
        r += 1
    }
    var h = g                                         // deep: rows are copied too
    h[49][49] = -1
    if g[49][49] != 49 { return 1 }
    g[0].push_back(7)
    if (g[0].size() != 2) || (h[0].size() != 1) { return 2 }
    unsafe { g.erase(g.begin() + 10, g.begin() + 40) }
    if (g.size() != 20) || (g[10].size() != 41) { return 3 }
    var cells: usize = 0
    for *row in g { cells += row->size() }
    if cells == 0 { return 4 }
    return 0
}

fn big() -> i32 {
    var v: [u64]
    var i: u64 = 0
    while i < 100000 { v.push_back(i * 3); i += 1 }
    if (v.size() != 100000) || (v[99999] != 299997) { return 1 }
    var t: u64 = 0
    for x in v { t += x }
    if t != 3 * (99999 * 100000 / 2) { return 2 }
    var w = v
    if w[12345] != 37035 { return 3 }
    return 0
}

fn main() -> i32 {
    var base_blocks = live_blocks
    var base_bytes = live_bytes
    var r = cp_vectors()
    if r != 0 { return 10 + r }
    r = mv_vectors()
    if r != 0 { return 20 + r }
    r = strings()
    if r != 0 { return 30 + r }
    r = nested()
    if r != 0 { return 40 + r }
    r = big()
    if r != 0 { return 50 + r }
    // everything the vectors allocated is back
    if live_blocks != base_blocks { return 60 }
    if live_bytes != base_bytes { return 61 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
