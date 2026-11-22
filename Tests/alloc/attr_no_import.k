// The allocation attributes are bound at the lowering, so a file with no
// import at all uses every form, with and without `in:`. The allocator named
// by `in:` is a class of the file (a bump allocator over a static buffer).

static dropped: i32 = 0

static pool: [u8; 4096]
static used: usize = 0
static pool_freed: i32 = 0

class Pool {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var at = (used + align - 1) / align * align
        used = at + size
        unsafe { return (&pool[0] as unsafe *u8) + at }
    }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { pool_freed += 1 }
}

class Item {
    pub var v: i32
    pub fn Item(self, v: i32) { self.v = v }
    @move fn Item(self, other: Self) = default
    fn op finally(self) { dropped += 1 }
}

fn main() -> i32 {
    var score: i32 = 0

    // Global allocator.
    var *a? = @try_create Item(1)
    if a? { score += a->v; @destroy a }

    var unsafe *p = @alloc(size: 16, align: 8)
    if p == &null { return 1 }
    unsafe { *p = 3 }
    p = @resize(size: 16, new_size: 64, align: 8) p
    if p == &null { return 2 }
    unsafe { score += *p }
    @free(size: 64, align: 8) p

    var u? = @alloc Item
    if u? {
        var *o = u.construct(5)
        score += o->v
        @free o
    }

    // A named allocator.
    var *c = @create(in: Pool) Item(7)
    score += c->v
    @destroy(in: Pool) c
    if pool_freed != 1 { return 3 }
    var unsafe *q = @alloc(size: 8, align: 8, in: Pool)
    @free(size: 8, align: 8, in: Pool) q
    if pool_freed != 2 { return 4 }

    // 1 + 3 + 5 + 7, and two destructors ran (`@free` runs none).
    if score != 16 { return 5 }
    return dropped + 40
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
