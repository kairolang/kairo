// Fixture: a complete ArenaAllocator for the `@set_scoped_allocator` class
// and struct tests. Eight arenas of 64 KiB over one static buffer, a bump
// pointer each, counting the arenas opened and closed, the blocks served
// and freed per arena, and which arena is current (0: none).
import builtin::base::alloc::*
import std::io::println

pub static pool:   [u8; 524288]
pub static used:   [usize; 8]
pub static live:   [u8; 8]
pub static opened: i32          = 0
pub static closed: i32          = 0
pub static cur:    usize        = 0
pub static served: [i32; 8]
pub static freedn: [i32; 8]

pub fn abase(k: usize) -> unsafe *u8 {
    unsafe {
        return (&pool[0] as unsafe *u8) + k * 65536
    }
}

/// The arena whose range holds `p`, or 8 for an address outside the pool.
pub fn aof(p: unsafe *const u8) -> usize {
    var a  = p as usize
    var lo = abase(0) as usize
    if a < lo || a >= lo + 524288 {
        return 8
    }

    return (a - lo) / 65536
}

pub class Arenas {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        if cur == 0 {
            println("FAIL: an arena allocation with no arena current")
            __builtin_abort()
        }

        var k  = cur - 1
        var at = align_up(used[k], align)
        if at + size > 65536 {
            return &null
        }

        used[k] = at + size
        served[k] += 1
        return abase(k) + at
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        freedn[aof(ptr)] += 1
    }

    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool {
        return n <= o
    }

    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        return realloc_by_copy<Arenas>(ptr, o, n, align)
    }

    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var unsafe *p = Arenas::alloc(size, align)
        if p != &null {
            __builtin_set_mem(p, 0 as byte, size)
        }

        return p
    }

    pub static fn arena_open() -> usize {
        for var k: usize = 0; k < 8; k += 1 {
            if live[k] == 0 {
                live[k]   = 1
                used[k]   = 0
                served[k] = 0
                freedn[k] = 0
                opened += 1
                return k + 1
            }
        }

        println("FAIL: more than eight arenas open")
        __builtin_abort()
    }

    pub static fn arena_close(arena: usize) {
        if live[arena - 1] == 0 {
            println("FAIL: an arena closed twice")
            __builtin_abort()
        }

        live[arena - 1] = 0
        closed += 1
    }

    pub static fn arena_enter(arena: usize) -> usize {
        var p = cur
        cur = arena
        return p
    }

    pub static fn arena_leave(previous: usize) {
        cur = previous
    }

    pub static fn arena_range(arena: usize) -> (unsafe *u8, unsafe *u8) {
        return (abase(arena - 1), abase(arena - 1) + 65536)
    }
}

/// The number of arenas open now.
pub fn open_now() -> i32 {
    return opened - closed
}

pub fn check(c: bool, what: string) {
    if !c {
        println(f"FAIL: {what}")
        __builtin_abort()
    }
}
