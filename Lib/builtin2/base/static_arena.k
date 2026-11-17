/// builtin/base/static_arena.k

import base::intrinsics::*

/// Global allocator for freestanding builds: a bump allocator over a static
/// buffer. Freeing the most recent block rolls back; any other free leaks
/// until program end. Size with -DKAIRO_STATIC_HEAP=<bytes>.
/// Single-threaded and not reentrant: no locking, and an allocation made
/// from an interrupt handler corrupts the arena.

// COMPILER-WORKAROUND(macro-in-untaken-eval-if): the size is declared in
// each branch rather than through a fallback `macro KAIRO_STATIC_HEAP!`
// under `eval if !defined!(...)`: a macro in an untaken branch still takes
// effect and would override the define's value.
eval if defined!(KAIRO_STATIC_HEAP) {
    priv eval STATIC_HEAP_BYTES: usize = KAIRO_STATIC_HEAP!
} else {
    priv eval STATIC_HEAP_BYTES: usize = 65536
}

@align(16) priv static arena_mem: [u8; STATIC_HEAP_BYTES]
priv static            arena_top: usize                   = 0

pub class StaticArena {
    /// `size` bytes aligned to `align`, or null when the arena cannot hold
    /// them. A non-power-of-two `align` traps: the rounding below would
    /// return a misaligned block.
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        if align == 0 || (align & (align - 1)) != 0 {
            __builtin_trap()
        }

        var base = unsafe &arena_mem[0] as usize
        var addr = (base + arena_top + align - 1) & ~(align - 1)
        var off  = addr - base
        if off > STATIC_HEAP_BYTES || size > STATIC_HEAP_BYTES - off {
            return &null
        }

        arena_top = off + size
        return unsafe &arena_mem[off]
    }

    /// Rolls the arena back when `ptr` is the most recent block; any other
    /// block stays allocated until the program ends.
    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        var off = (ptr as usize) - (unsafe &arena_mem[0] as usize)
        if off + size == arena_top {
            arena_top = off
        }
    }

    /// A shrink always succeeds in place, and gives the bytes back when `ptr`
    /// is the most recent block. A growth succeeds only for the most recent
    /// block, and only while the arena has room.
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

    /// `resize` when it succeeds; otherwise a new block holding the first
    /// `min(old_size, new_size)` bytes, the old one freed. Null, with the old
    /// block untouched, when the arena is full.
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

    /// `alloc`, then zeroed: a rolled-back block may hold old bytes.
    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var unsafe *p = StaticArena::alloc(size, align)
        if p != &null {
            __builtin_set_mem(p, 0, size)
        }

        return p
    }
}
