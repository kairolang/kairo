/// builtin/base/static_arena.k

import base::intrinsics::*

/// Global allocator for freestanding builds: a bump allocator over a static
/// buffer. Freeing the most recent block rolls back; any other free leaks
/// until program end. Size with -DKAIRO_STATIC_HEAP=<bytes>.
/// Single-threaded and not reentrant: no locking, and an allocation made
/// from an interrupt handler corrupts the arena.

eval if !defined!(KAIRO_STATIC_HEAP) {
    macro KAIRO_STATIC_HEAP! { 65536 }
}

priv eval STATIC_HEAP_BYTES: usize = KAIRO_STATIC_HEAP!

@align(16) priv static arena_mem: [u8; STATIC_HEAP_BYTES]
priv static            arena_top: usize                   = 0

pub class StaticArena {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var base = unsafe &arena_mem[0] as usize
        var addr = (base + arena_top + align - 1) & ~(align - 1)
        var off  = addr - base
        if off > STATIC_HEAP_BYTES || size > STATIC_HEAP_BYTES - off {
            return &null
        }

        arena_top = off + size
        return unsafe &arena_mem[off]
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        var off = (ptr as usize) - (unsafe &arena_mem[0] as usize)
        if off + size == arena_top {
            arena_top = off
        }
    }

    pub static fn resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool {
        var off = (ptr as usize) - (unsafe &arena_mem[0] as usize)
        if new_size <= old_size {
            if off + old_size == arena_top {
                arena_top = off + new_size
            }

            return true
        }

        if off + old_size != arena_top || new_size > STATIC_HEAP_BYTES - off {
            return false
        }

        arena_top = off + new_size
        return true
    }

    pub static fn realloc(ptr:      unsafe *u8,
                          old_size: usize,
                          new_size: usize,
                          align:    usize) -> unsafe *u8 {
        if StaticArena::resize(ptr, old_size, new_size, align) {
            return ptr
        }

        var unsafe *dst = StaticArena::alloc(new_size, align)
        if dst == &null {
            return &null
        }

        var n = if old_size < new_size => old_size else => new_size
        __builtin_copy(dst, ptr, n)
        StaticArena::free(ptr, old_size, align)
        return dst
    }

    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var unsafe *p = StaticArena::alloc(size, align)
        if p != &null {
            __builtin_set_mem(p, 0, size)
        }

        return p
    }
}
