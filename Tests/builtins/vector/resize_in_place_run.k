// Growth tries an in-place resize first. Under a bump allocator that grows
// only its last block, a vector whose block is last grows without moving
// (element 0 keeps its address and, for elements that are not relocatable,
// no element is moved), and one whose block is not last is moved: by
// realloc for relocatable elements, element by element otherwise.
// shrink_to_fit shrinks in place.

import self::inputs::elems::*
import std::io

@align(64) static ARENA: [u8; 1048576]
static TOP: usize = 0
static RESIZED: i64 = 0
static REFUSED: i64 = 0
static REALLOCS: i64 = 0

class Bump {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var base = unsafe &ARENA[0] as usize
        var at   = (base + TOP + align - 1) & ~(align - 1)
        if at - base + size > 1048576 {
            return &null
        }

        TOP = at - base + size
        return unsafe &ARENA[at - base]
    }

    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        var p = Bump::alloc(size, align)
        if p != &null {
            unsafe {
                __builtin_set_mem(p, 0 as byte, size)
            }
        }

        return p
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        var off = (ptr as usize) - (unsafe &ARENA[0] as usize)
        if off + size == TOP {
            TOP = off
        }
    }

    pub static fn resize(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> bool {
        var off = (ptr as usize) - (unsafe &ARENA[0] as usize)
        if off + old_size != TOP || off + new_size > 1048576 {
            if new_size <= old_size {
                RESIZED += 1
                return true
            }

            REFUSED += 1
            return false
        }

        TOP = off + new_size
        RESIZED += 1
        return true
    }

    pub static fn realloc(ptr: unsafe *u8, old_size: usize, new_size: usize, align: usize) -> unsafe *u8 {
        REALLOCS += 1
        var p = Bump::alloc(new_size, align)
        if p == &null {
            return &null
        }

        unsafe {
            __builtin_copy(p, ptr as unsafe *const u8, if old_size < new_size => old_size else => new_size)
        }

        Bump::free(ptr, old_size, align)
        return p
    }
}

@set_global_allocator(Bump)

fn addr_i32(const v: [i32]) -> usize {
    return unsafe &v[0] as usize
}

fn main() -> i32 {
    var bad: i64 = 0
    var r1: i64 = 0
    var r2: i64 = 0
    var r3: i64 = 0
    var r4: i64 = 0
    var moved_live: i64 = 0
    {
        // Last block: every growth is in place.
        var v: [i32]
        v.push(0)
        var a0 = addr_i32(v)
        for var i: i32 = 1; i < 200; ++i {
            v.push(i)
        }

        if addr_i32(v) != a0 || RESIZED < 3 || REFUSED != 0 || REALLOCS != 0 {
            bad += 1
        }

        r1 = RESIZED

        // Not last: the resize is refused and realloc moves the block.
        var w: [i32]
        w.push(7)
        while v.size() < v.capacity() {
            v.push(v.size() as i32)
        }

        v.push(v.size() as i32)
        if addr_i32(v) == a0 || REFUSED != 1 || REALLOCS != 1 {
            bad += 1
        }

        for var i: usize = 0; i < v.size(); ++i {
            if v[i] != i as i32 {
                bad += 1
            }
        }

        r2 = REFUSED

        // shrink_to_fit in place.
        var resized = RESIZED
        v.truncate(10)
        v.shrink_to_fit()
        if v.capacity() != 10 || RESIZED != resized + 1 || REALLOCS != 1 {
            bad += 1
        }
    }

    {
        // Elements that are not relocatable: in place, nothing is moved; not
        // in place, each element is moved once.
        var t: [Tracked]
        for var i: i64 = 0; i < 16; ++i {
            t.push(Tracked(i))
        }

        var live = LIVE
        var refused = REFUSED
        t.push(Tracked(16))
        if LIVE != live + 1 || REFUSED != refused {
            bad += 1
        }

        r3 = RESIZED
        var u: [Tracked]
        u.push(Tracked(99))
        while t.size() < t.capacity() {
            t.push(Tracked(t.size() as i64))
        }

        var before = LIVE
        t.push(Tracked(t.size() as i64))
        moved_live = LIVE - before
        if REFUSED != refused + 1 || REALLOCS != 1 {
            bad += 1
        }

        for var i: usize = 0; i < t.size(); ++i {
            if t[i].get() != i as i64 {
                bad += 1
            }
        }

        r4 = REFUSED
    }

    if LIVE != 0 || ERRS != 0 {
        bad += 1
    }

    io::println(f"resize: bad={bad} resized>={r1 >= 3} refused={r2} tracked_refused={r4} moved_live={moved_live}")
    return bad as i32
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: resize: bad=0 resized>=true refused=1 tracked_refused=2 moved_live=1
