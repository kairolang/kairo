// `@set_scoped_allocator(A)` on a class: the object owns an arena of A. The
// constructor, every method (a `const` one too) and the destructor's body
// allocate from it; a static method does not. A string, a vector and a hash
// map field are served by the arena and freed back into it, the arena is
// closed exactly once, after the fields' blocks went back, and no block of
// it reaches the program's global allocator.
import builtin::base::alloc::*
import inputs::counting_arenas::*
import std::io::println

static stray:   i32 = 0
static g_alloc: i32 = 0

class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        g_alloc += 1
        return System::alloc(size, align)
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        if aof(ptr) != 8 {
            stray += 1
            return
        }

        System::free(ptr, size, align)
    }

    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool {
        return false
    }

    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        return realloc_by_copy<G>(ptr, o, n, align)
    }

    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        g_alloc += 1
        return System::alloc_zeroed(size, align)
    }
}

@set_global_allocator(G)

static seen_in_dtor: usize = 0

@set_scoped_allocator(Arenas)
class Log {
    pub var text:  string
    pub var items: [i32]
    pub var index: {i32: i32}

    fn Log(self) {
        self.text.push_str(
            "built in the arena, long enough to leave the small buffer ..........",
        )
    }

    fn add(self, n: i32) {
        self.items.push(n)
        self.index.insert(n, n * 2)
        self.text.push_str(
            "added ................................................................",
        )
    }

    fn arena(const self) -> usize {
        check(cur != 0, "a const method opens the arena")
        return cur
    }

    fn size(const self) -> usize = self.items.size()

    static fn outside() -> usize {
        var s = "a static method allocates from the global allocator ..................."
        s.push_str("!")
        return cur
    }

    fn op finally(self) {
        seen_in_dtor = cur
        self.text.push_str(
            "the destructor's body allocates in the arena too ......................",
        )
    }
}

fn main() -> i32 {
    var k: usize = 0
    {
        var l = Log()
        check(open_now() == 1, "one arena per object")
        k = l.arena() - 1
        check(served[k] == 1, "the constructor's string came from the arena")
        check(cur == 0, "no arena current between calls")
        var s0 = served[k]
        for var i = 0; i < 20; i += 1 {
            l.add(i)
        }

        check(l.size() == 20, "the vector grew")
        check(l.index.size() == 20, "the map grew")
        check(
            served[k] >= s0 + 3,
            "the string, the vector and the map grew in the arena",
        )

        var g = g_alloc
        check(Log::outside() == 0, "a static method opens no arena")
        check(
            g_alloc > g,
            "a static method allocates from the global allocator",
        )

        check(cur == 0, "no arena current after a static method")
    }

    check(
        seen_in_dtor == k + 1,
        "the destructor's body ran in the object's arena",
    )

    check(opened == 1 && closed == 1, "the arena closed exactly once")
    check(
        freedn[k] == served[k],
        "every block the arena served went back to it",
    )

    check(stray == 0, "no block of the arena reached the global allocator")
    check(cur == 0, "no arena current at the end")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
