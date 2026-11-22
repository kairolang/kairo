// A class that derives from a `@set_scoped_allocator(A)` class does not
// inherit the attribute: its own methods open no arena and allocate from
// the allocator in effect where they are called, while the base's methods,
// called on the derived object, still open the base part's arena. A derived
// class that carries the attribute itself has two arenas, its base part's
// and its own. Its constructor's guard follows the base initializer, which
// stays its first statement; the function form does the same.
import builtin::base::alloc::*
import inputs::counting_arenas::*
import std::io::println

@set_scoped_allocator(Arenas)
class Base {
    pub var text: string
    fn Base(self, const s: string) {
        self.text.push_str(s)
        self.text.push_str(
            " ......................................................",
        )
    }

    fn grow(self) -> usize {
        self.text.push_str(
            "the base grows ........................................................",
        )

        return cur
    }
}

class Derived derives Base {
    pub var own: string
    fn Derived(self) {
        Base::Base(self, "derived")
        check(cur == 0, "the derived constructor opens no arena")
        self.own.push_str(
            "the derived part's own field, from the global heap ....................",
        )
    }

    fn mine(self) -> usize {
        return cur
    }
}

@set_scoped_allocator(Arenas)
class Dog derives Base {
    pub var name: string
    fn Dog(self) {
        Base::Base(self, "dog")
        self.name.push_str(
            "a dog's name, in the dog's own arena ..................................",
        )
    }

    fn mine(const self) -> usize {
        return cur
    }
}

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

class Animal {
    pub var legs: i32
    fn Animal(self, legs: i32) {
        self.legs = legs
    }
}

class Cat derives Animal {
    pub var n: usize = 0
    @set_scoped_allocator(Scoped)
    fn Cat(self) {
        Animal::Animal(self, 4)
        var s = "a local of the constructor, in the scope .............................".copy()
        s.push_str("!")
        self.n = s.size()
    }
}

fn main() -> i32 {
    {
        var d = Derived()
        check(open_now() == 1, "the base part has an arena")
        var id = d.grow()
        check(
            id != 0 && served[id - 1] >= 2,
            "the base's method allocates in the base part's arena",
        )

        check(d.mine() == 0, "the derived class's own method opens no arena")
    }

    check(opened == closed, "derived: the base part's arena closed once")

    {
        var dg = Dog()
        check(open_now() == 2, "a derived class with the attribute: two arenas")
        var own  = dg.mine()
        var base = dg.grow()
        check(
            own != 0 && base != 0 && own != base,
            "its own arena and its base part's",
        )

        check(
            served[own - 1] >= 1,
            "its constructor's body ran in its own arena",
        )
    }

    check(opened == closed, "dog: both arenas closed once")

    {
        var s0 = sserved
        var c  = Cat()
        check(
            c.legs == 4 && c.n > 0 && sserved > s0,
            "the function form follows the base initializer",
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
