// The raising allocation forms. `@try_create` / `try_create<T>` /
// `try_create_in<T, A>` return the object, or raise an AllocError carrying
// the size and alignment asked for, with no constructor run.
// `@try_resize_in_place` / `try_resize_raw_in_place` / `try_resize_in_place<A>`
// raise one where `@resize_in_place` gives false, leaving the block as it was.

import builtin::base::alloc::*
import std::io::println

static ctors: i32 = 0
static dtors: i32 = 0
static fails: i32 = 0

// Every request fails.
class Failing {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
}

// The global allocator: System, resizing in place only to shrink.
class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { System::free(ptr, size, align) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<G>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return System::alloc_zeroed(size, align) }
}

@set_global_allocator(G)

// A scope whose every request fails.
class FailingScope {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
    pub static fn enter() -> usize { return 0 }
    pub static fn leave(m: usize) { }
    pub static fn range() -> (unsafe *u8, unsafe *u8) { return (&null, &null) }
}

@align(16)
class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v; ctors += 1 }
    @move fn Box(self, other: Self) = default
    fn op finally(self) { dtors += 1 }
}

fn check(c: bool, what: string) {
    if !c {
        println(f"FAIL: {what}")
        fails += 1
    }
}

fn is_box_error(const e: AllocError) -> bool {
    return e.size() == sizeof Box && e.align() == alignof Box
}

fn creates() {
    // Served: the object, constructed.
    var *a = try @try_create Box(5) catch e: AllocError => @create Box(-1)
    check(a->v == 5 && ctors == 1, "@try_create returns the object")
    @destroy a
    var *b = try try_create<Box>(6) catch e: AllocError => @create Box(-1)
    check(b->v == 6, "try_create<T> returns the object")
    destroy(b)

    // Refused through `in:`: AllocError with the size and alignment of a Box.
    var raised = 0
    try {
        var *c = @try_create(in: Failing) Box(7)
        check(false, "@try_create(in: Failing) returned")
    } catch e: AllocError {
        check(is_box_error(e), f"@try_create(in: Failing) reports the request: {e.size()} {e.align()}")
        raised += 1
    }

    try {
        var *d = try_create_in<Box, Failing>(8)
        check(false, "try_create_in returned")
    } catch e: AllocError {
        check(is_box_error(e), "try_create_in reports the request")
        raised += 1
    }

    // Refused by the scope in effect.
    {
        var scope = AllocatorScope<FailingScope>()
        try {
            var *f = @try_create Box(9)
            check(false, "@try_create in a failing scope returned")
        } catch e: AllocError {
            check(is_box_error(e), "@try_create in a failing scope reports the request")
            raised += 1
        }
    }

    check(raised == 3, f"every refusal raised: {raised}")
    check(ctors == 2 && dtors == 2, f"no constructor ran for a refused request: {ctors} {dtors}")
}

fn fill(p: unsafe *u8, n: usize) {
    for var i: usize = 0; i < n; i += 1 { unsafe { *(p + i) = (i + 1) as u8 } }
}

fn filled(p: unsafe *u8, n: usize) -> bool {
    for var i: usize = 0; i < n; i += 1 { unsafe { if *(p + i) != (i + 1) as u8 { return false } } }
    return true
}

fn resizes() {
    var unsafe *m = @alloc(size: 64, align: 8)
    fill(m, 64)
    var m0 = m as usize

    // The bool form: false to grow, true to shrink.
    check(!(@resize_in_place(size: 64, new_size: 128, align: 8) m), "@resize_in_place refuses growth")
    check(@resize_in_place(size: 64, new_size: 48, align: 8) m, "@resize_in_place shrinks")

    // The raising form: AllocError (new size, alignment) to grow, nothing to shrink.
    var grew = true
    try {
        @try_resize_in_place(size: 48, new_size: 96, align: 8) m
    } catch e: AllocError {
        check(e.size() == 96 && e.align() == 8, f"@try_resize_in_place reports the request: {e.size()} {e.align()}")
        grew = false
    }

    check(!grew && m as usize == m0 && filled(m, 48), "a refused resize leaves the block as it was")
    var shrank = true
    try {
        @try_resize_in_place(size: 48, new_size: 32, align: 8) m
    } catch e: AllocError {
        shrank = false
    }

    check(shrank && filled(m, 32), "@try_resize_in_place shrinks without raising")
    var direct = false
    try {
        try_resize_raw_in_place(m, 32, 4096, 8)
    } catch e: AllocError {
        direct = e.size() == 4096
    }

    check(direct, "try_resize_raw_in_place raises")

    // Zero sizes are refusals, as for the bool form.
    var zero = false
    try {
        @try_resize_in_place(size: 32, new_size: 0, align: 8) m
    } catch e: AllocError {
        zero = e.size() == 0
    }

    check(zero, "a zero size raises")

    // `in: A`: A's resize decides.
    var via_in = false
    try {
        @try_resize_in_place(size: 32, new_size: 16, align: 8, in: Failing) m
    } catch e: AllocError {
        via_in = e.size() == 16 && e.align() == 8
    }

    check(via_in, "@try_resize_in_place(in: Failing) raises")
    check(!(@resize_in_place(size: 32, new_size: 16, align: 8, in: Failing) m), "@resize_in_place(in: Failing) is false")
    var generic = false
    try {
        try_resize_in_place<G>(m, 32, 16, 8)
        generic = true
    } catch e: AllocError {
    }

    check(generic && filled(m, 16), "try_resize_in_place<A> shrinks through A")
    @free(size: 16, align: 8) m
}

fn errors() {
    var e = AllocError::of(1000, 64)
    check(e.size() == 1000 && e.align() == 64, "AllocError keeps size and alignment")
    check(e.op panic() == "allocation failed: 1000 bytes at alignment 64", f"message: {e.op panic()}")
    var huge = AllocError::of(usize::MAX, 1)
    check(huge.size() == ((1 as usize) << 56) - 1 && huge.align() == 1, "a huge size saturates")
    check(sizeof AllocError == 8, "AllocError is one word")
}

fn main() -> i32 {
    creates()
    resizes()
    errors()
    println(f"done, {fails} failures")
    return fails
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: done, 0 failures
