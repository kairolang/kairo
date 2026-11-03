// Kairo only: the scoped-allocator stack. DEPTH scopes are opened, then N
// operations of MODE run at the innermost level:
//   0  alloc + free from the innermost scope
//   1  a global block freed inside the scopes
//   2  a block from the outermost scope freed at the top
//   3  open and close one more scope
import builtin::base::alloc::*
ffi "c++" import "bench_env.h"

// 128 arenas of 4 KiB; arena k belongs to the scope opened at depth k.
static arenas: [u8; 524288]
static cursor: [usize; 128]
static level: usize = 0      // the depth of the innermost scope the bench opened

fn base(k: usize) -> unsafe *u8 { unsafe { return (&arenas[0] as unsafe *u8) + k * 4096 } }

class Bump {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var k = level - 1
        var at = align_up(cursor[k], align)
        if at + size > 4096 { cursor[k] = 0; at = 0 }
        cursor[k] = at + size
        return base(k) + at
    }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return n <= o }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return realloc_by_copy<Bump>(ptr, o, n, align) }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return Bump::alloc(size, align) }
    static fn enter() -> usize { return cursor[level - 1] }
    static fn leave(m: usize) { cursor[level - 1] = m }
    static fn range() -> (unsafe *u8, unsafe *u8) { return (base(level - 1), base(level - 1) + 4096) }
}

static mode: i32 = 0
static iters: i32 = 0
static sink: usize = 0

@no_inline fn run() {
    var unsafe *bottom = base(0)
    for var i = 0; i < iters; i += 1 {
        if mode == 0 {          // block from the innermost scope
            var unsafe *p = alloc_raw(16, 8)
            free_raw(p, 16, 8)
        } else if mode == 1 {   // global block freed inside the scopes
            var unsafe *p = alloc_bytes<System>(16, 8)
            free_raw(p, 16, 8)
        } else if mode == 2 {   // block from the outermost scope
            free_raw(bottom, 16, 8)
        } else {                // open and close one more scope
            level += 1
            { var s = AllocatorScope<Bump>() }
            level -= 1
        }
    }
}

fn nest(d: usize) {
    if d == 0 { run(); return }
    level += 1
    var s = AllocatorScope<Bump>()
    nest(d - 1)
    level -= 1
}

fn main() -> i32 {
    var depth = bench_depth() as usize
    mode = bench_mode() as i32
    iters = bench_n() as i32
    nest(depth)
    return 0
}
