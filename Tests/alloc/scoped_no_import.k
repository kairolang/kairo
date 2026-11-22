// `@set_scoped_allocator(A)` expands to alloc.k's AllocatorScope<A>, so a
// program whose only allocation construct is the attribute needs no import
// at all. The guard's name is bound at the expansion, not looked up: a
// hand-written `AllocatorScope<A>()` with no import is still undeclared
// (inputs/bare_scope.k).

static buf: [u8; 65536]
static cur: usize = 0
static opened: i32 = 0
static closed: i32 = 0

fn lo() -> unsafe *u8 { unsafe { return &buf[0] as unsafe *u8 } }

class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var at = (cur + align - 1) / align * align
        cur = at + size
        return lo() + at
    }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        var unsafe *q = Bump::alloc(n, align)
        __builtin_copy(q, ptr, if o < n => o else => n)
        return q
    }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var unsafe *p = Bump::alloc(size, align)
        __builtin_set_mem(p, 0 as byte, size)
        return p
    }
    pub static fn enter() -> usize { opened += 1; return cur }
    pub static fn leave(m: usize) { closed += 1; cur = m }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (lo(), lo() + 65536) }
}

fn inside(p: *const u8) -> bool {
    var a = unsafe (p as unsafe *const u8) as usize
    return a >= (lo() as usize) && a < (lo() as usize) + 65536
}

fn long_string() -> string {
    var s = ""
    for var i = 0; i < 200; i += 1 { s.push('x') }
    return s
}

@set_scoped_allocator(Bump)
fn on_fn() -> bool {
    var s = long_string()
    return inside(s.data())
}

fn main() -> i32 {
    if !on_fn() || opened != 1 || closed != 1 { return 1 }
    var in_block = false
    @set_scoped_allocator(Bump) {
        var s = long_string()
        in_block = inside(s.data())
    }
    if !in_block || opened != 2 || closed != 2 { return 2 }
    var g = long_string()
    if inside(g.data()) { return 3 }
    return 42
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %S/inputs/bare_scope.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BARE
// BARE: bare_scope.k:{{[0-9]+}}:{{[0-9]+}}: error [R020E]: use of undeclared identifier 'AllocatorScope'

// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
