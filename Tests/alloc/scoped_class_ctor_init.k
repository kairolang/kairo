// Constructors of `@set_scoped_allocator(A)` classes that initialize fields
// in place (a const field, a field whose type has no default, an array
// field) run in two parts: what comes before the last such write runs
// before the object exists, and the arena's guard opens the part after it.
// The constructor's body is written as usual. What runs before allocates
// from the allocator in effect where the object is built; what runs after
// allocates from the object's arena. A `@copy` constructor gives the copy
// an arena of its own. `@set_scoped_allocator(A)` written on such a
// constructor (the function form) opens its scope at the same place.
import builtin::base::alloc::*
import inputs::counting_arenas::*
import std::io::println

static g_alloc: i32 = 0

class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        g_alloc += 1
        return System::alloc(size, align)
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
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

fn label(n: i32) -> string {
    check(cur == 0, "before the frontier no arena is open")
    var s = "a label computed before the object exists ...........................".copy()
    s.push_str(f"{n}")
    return s
}

@set_scoped_allocator(Arenas)
class Fixed {
    const id:    i32
    const name:  string
    var   ready: bool
    var   cells: [i32; 4]
    var   text:  string

    fn Fixed(self, id: i32) {
        self.id    = id
        self.name  = label(id)
        self.ready = true
        self.cells = [1, 2, 3, 4]
        check(cur != 0, "after the frontier the arena is open")
        self.text.push_str(
            "after the frontier, in the arena ......................................",
        )
    }

    fn id_now(const self) -> usize {
        return cur
    }
}

@set_scoped_allocator(Arenas)
class Copyable {
    pub var text: string
    fn Copyable(self) {
        self.text.push_str(
            "copyable, long enough to leave the small buffer .........................",
        )
    }

    @copy
    fn Copyable(self, other: Self) {
        self.text = other.text.copy()
    }

    fn id(const self) -> usize {
        return cur
    }
}

// The function form on a constructor that initializes a const field.
static sbuf:    [u8; 65536]
static sused:   usize       = 0
static sserved: i32         = 0

class Scoped {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        var at = align_up(sused, align)
        sused = at + size
        sserved += 1
        unsafe {
            return (&sbuf[0] as unsafe *u8) + at
        }
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool {
        return n <= o
    }

    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        return realloc_by_copy<Scoped>(ptr, o, n, align)
    }

    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        return Scoped::alloc(size, align)
    }

    pub static fn enter() -> usize {
        return 0
    }

    pub static fn leave(m: usize) { }
    pub static fn range() -> (unsafe *u8, unsafe *u8) {
        unsafe {
            return (&sbuf[0] as unsafe *u8, (&sbuf[0] as unsafe *u8) + 65536)
        }
    }
}

// The scope closes when the constructor returns, so what it serves must
// not outlive the body: the local does not.
class Plain {
    const   id: i32
    pub var n:  usize = 0

    @set_scoped_allocator(Scoped)
    fn Plain(self, id: i32) {
        self.id = id
        var s = "after the frontier, in the scope ......................................".copy()
        s.push_str("!")
        self.n = s.size()
    }
}

fn main() -> i32 {
    {
        var g0 = g_alloc
        var f  = Fixed(7)
        check(
            f.id == 7 && f.ready && f.cells[3] == 4,
            "every field built in place",
        )

        check(
            g_alloc > g0,
            "the part before the frontier allocated from the global allocator",
        )

        var id = f.id_now()
        check(
            served[id - 1] >= 1,
            "the part after the frontier allocated in the arena",
        )
    }

    check(opened == closed, "the split constructor's arena closed once")

    {
        var a = Copyable()
        var b = a
        check(open_now() == 2, "the copy has an arena of its own")
        check(a.id() != b.id(), "two arenas")
        check(served[b.id() - 1] >= 1, "the copy's text is in its own arena")
        check(b.text.size() == a.text.size(), "copied")
    }

    check(opened == closed, "the copy constructor: every arena closed once")

    {
        var s0 = sserved
        var p  = Plain(3)
        check(
            p.id == 3 && p.n > 0 && sserved > s0,
            "the function form's scope opens after the frontier",
        )
    }

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
