// `@create`, `@try_create` and `@destroy` with and without `in: A`: the
// block comes from, and goes back to, the allocator the attribute names (the
// global one without `in:`), in both construction shapes, for a generic
// class and for a type named through a `::` path. A destructor runs exactly
// once per `@destroy`.

import builtin::base::alloc::*
import std::io::println

static a_served: i32 = 0
static a_freed:  i32 = 0
static b_served: i32 = 0
static b_freed:  i32 = 0
static g_served: i32 = 0
static g_freed:  i32 = 0

class A {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { a_served += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { a_freed += 1; System::free(ptr, size, align) }
}

class B {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { b_served += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { b_freed += 1; System::free(ptr, size, align) }
}

class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 { g_served += 1; return System::alloc(size, align) }
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { g_freed += 1; System::free(ptr, size, align) }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<G>(ptr, o, n, align) }
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { g_served += 1; return System::alloc_zeroed(size, align) }
}

@set_global_allocator(G)

static dtors: i32 = 0

class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
    @move fn Box(self, other: Self) = default
    fn op finally(self) { dtors += 1 }
}

class <T> Cell {
    pub var v: T
    pub fn Cell(self, v: T) { self.v = v }
    @move fn Cell(self, other: Self) = default
    fn op finally(self) { dtors += 1 }
}

struct Point {
    pub var x: i32
    pub var y: i32
}

module shapes {
    pub class Cube {
        pub var side: i32
        pub fn Cube(self, side: i32) { self.side = side }
        @move fn Cube(self, other: Self) = default
        fn op finally(self) { dtors += 1 }
    }
}

fn check(c: bool, what: string) { if !c { println(f"FAIL: {what}"); __builtin_abort() } }

fn main() -> i32 {
    // The global allocator, no `in:`.
    var *a = @create Box(1)
    check(g_served == 1 && a_served == 0 && b_served == 0, "create without in: is served by the global allocator")
    @destroy a
    check(g_freed == 1 && dtors == 1, "destroy without in: frees to the global allocator, one destructor")

    // `in: A` and `in: B` name the allocator, in both shapes.
    var *x = @create(in: A) Box(2)
    var *y = @create(in: B) Box(3)
    var *p = @create(in: A) Point { x: 4, y: 5 }
    var *q = @create(in: B) Point { x: 6, y: 7 }
    check(a_served == 2 && b_served == 2 && g_served == 1, "create in: routes to the named allocator")
    check(x->v == 2 && y->v == 3 && p->x == 4 && p->y == 5 && q->x == 6 && q->y == 7, "values constructed")
    @destroy(in: A) x
    check(a_freed == 1 && b_freed == 0 && dtors == 2, "destroy in: A")
    @destroy(in: B) y
    @destroy(in: A) p
    @destroy(in: B) q
    check(a_freed == 2 && b_freed == 2 && g_freed == 1 && dtors == 3, "every block returned to its own allocator")

    // `@try_create`.
    var t: *Box? = try @try_create Box(8) catch e: AllocError => null
    var u: *Box? = try @try_create(in: A) Box(9) catch e: AllocError => null
    var w: *Point? = try @try_create(in: B) Point { x: 1, y: 2 } catch e: AllocError => null
    check(g_served == 2 && a_served == 3 && b_served == 3, "try_create routing")
    check(t? && u? && w?, "try_create succeeded")
    if t? { check(t->v == 8, "try_create value"); @destroy t }
    if u? { check(u->v == 9, "try_create in: value"); @destroy(in: A) u }
    if w? { check(w->y == 2, "try_create init value"); @destroy(in: B) w }
    check(g_freed == 2 && a_freed == 3 && b_freed == 3 && dtors == 5, "try_create blocks returned")

    // A generic class and a `::` path.
    var *c = @create Cell<i32>(10)
    var *d = @create(in: A) Cell<i32>(11)
    var *e = @create(in: B) shapes::Cube(12)
    var *f = @create shapes::Cube(13)
    check(c->v == 10 && d->v == 11 && e->side == 12 && f->side == 13, "generic and path values")
    check(g_served == 4 && a_served == 4 && b_served == 4, "generic and path routing")
    @destroy c
    @destroy(in: A) d
    @destroy(in: B) e
    @destroy f
    check(g_freed == 4 && a_freed == 4 && b_freed == 4 && dtors == 9, "generic and path destroyed once each")

    // The parenthesised operand spelling.
    var *z = @create(in: A) Box(20)
    @destroy(in: A) (z)
    check(a_freed == 5 && dtors == 10, "destroy of a parenthesised operand")

    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
