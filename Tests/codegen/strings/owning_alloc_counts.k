// What the owning string allocates and frees, counted by a global allocator
// that forwards to System: a literal and its copies allocate nothing; the
// first write to a copy allocates once and leaves the literal intact; a
// copy of an owned string is one block; every block is freed by the
// destructor (live == 0 once the strings are gone); f-strings and the
// string agree on the allocator (FmtBuf's block is the string's, freed by
// it); and 300000 appends grow geometrically, so they cost a few dozen
// allocator calls, not one per append.

import builtin::base::alloc::*

static allocs: i64 = 0
static frees: i64 = 0
static resizes: i64 = 0
static live: i64 = 0

class Counting {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { allocs += 1; live += 1; return System::alloc(size, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { allocs += 1; live += 1; return System::alloc_zeroed(size, align) }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { frees += 1; live -= 1; System::free(ptr, size, align) }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { resizes += 1; return System::resize(ptr, o, n, align) }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { resizes += 1; return System::realloc(ptr, o, n, align) }
}

@set_global_allocator(Counting)

@no_inline fn literal_copies() -> i32 {
    var a = "literal"
    var b = a
    var c = b
    var d: string = string()
    d = c
    if (d != "literal") || (b.capacity() != 0) { return 1 }
    return 0
}

@no_inline fn mutate_copy() -> i32 {
    var a = "literal"
    var b = a
    b.push_back(33)
    if (a != "literal") || (b != "literal!") || (a.capacity() != 0) { return 1 }
    var c = b                       // deep: one exact block
    c.push_back(63)
    if (b != "literal!") || (c != "literal!?") { return 2 }
    return 0
}

@no_inline fn fstrings() -> i32 {
    var n = 12345
    var f = f"value={n}"            // FmtBuf's block becomes the string's
    var g = f                       // a deep copy of it
    g += "!"
    if (f != "value=12345") || (g != "value=12345!") { return 1 }
    return 0
}

@no_inline fn appends(count: usize) -> usize {
    var s = string()
    for var i: usize = 0; i < count; ++i { s += "ab" }
    return s.size()
}

fn main() -> i32 {
    if literal_copies() != 0 { return 1 }
    if (allocs != 0) || (frees != 0) { return 2 }

    if mutate_copy() != 0 { return 3 }
    if allocs != 2 { return 4 }     // b's first push, c's copy; c's growth is a resize
    if live != 0 { return 5 }       // every block freed by a destructor

    var base = allocs
    if fstrings() != 0 { return 6 }
    if live != 0 { return 7 }
    if allocs - base != 2 { return 8 }   // FmtBuf's block, g's copy (it grows in place or by realloc)

    var before = allocs + resizes
    if appends(300000) != 600000 { return 9 }
    var calls = allocs + resizes - before
    if (calls > 40) || (live != 0) { return 10 }

    // a block past mimalloc's small range, then past 1 MiB
    {
        var big = string()
        big.reserve(5000)
        for var i: usize = 0; i < 2000000; ++i { big.push_back(120) }
        if (big.size() != 2000000) || (big.codepoints() != 2000000) { return 11 }
    }
    if live != 0 { return 12 }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
