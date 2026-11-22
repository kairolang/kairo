// More method shapes of `@set_scoped_allocator(A)` records, each opening
// the object's arena: a method defined out of line, an operator, a
// generic method, a struct's constructor and operator, a constructor that
// both initializes its base and builds a const field in place (the guard
// opens after the frontier, the base initializer stays first), and an
// assignment through a hand-written `@move` constructor. A class with the
// attribute is move-only unless it writes a `@copy` constructor, so its
// base is move-only too.
import inputs::counting_arenas::*
import std::io::println

@set_scoped_allocator(Arenas)
class Log {
    pub var text: string
    fn add(self)
    fn op +=(self, const s: string) {
        self.text.push_str(s)
    }

    fn <U> put(self, u: U) -> usize {
        self.text.push_str(
            "generic method ......................................................",
        )

        return cur
    }
}

fn Log::add(self) {
    self.text.push_str(
        "out of line ............................................................",
    )
}

@set_scoped_allocator(Arenas)
struct S {
    pub var text: string
    fn S(self) {
        self.text.push_str(
            "a struct constructor .................................................",
        )
    }

    fn op +=(self, const s: string) {
        self.text.push_str(s)
    }
}

class Animal {
    pub var legs: i32
    fn Animal(self, legs: i32) {
        self.legs = legs
    }

    @move fn Animal(self, other: Self) = default
}

@set_scoped_allocator(Arenas)
class Dog derives Animal {
    const   id:   i32
    pub var text: string
    fn Dog(self, id: i32) {
        Animal::Animal(self, 4)
        self.id = id
        check(
            cur != 0,
            "the split derived constructor opens the arena after the frontier",
        )

        self.text.push_str(
            "a dog ..................................................................",
        )
    }
}

@set_scoped_allocator(Arenas)
class Mover {
    pub var text: string
    fn Mover(self) {
        self.text.push_str(
            "a mover ...............................................................",
        )
    }

    @move
    fn Mover(self, other: Self) {
        self.text = other.text
    }

    fn id(const self) -> usize {
        return cur
    }
}

fn main() -> i32 {
    {
        var l  = Log()
        var s0 = used[0]
        l.add()
        check(used[0] > s0, "an out-of-line method allocates in the arena")
        s0 = used[0]
        l += "an operator ........................................................."
        check(used[0] > s0, "an operator allocates in the arena")
        check(l.put(3) != 0, "a generic method opens the arena")
    }

    check(opened == closed, "out of line, operator, generic method: closed")
    {
        var s = S()
        check(served[0] > 0, "a struct constructor allocates in the arena")
        s += "struct operator ........................................................"
    }

    check(opened == closed, "struct: closed")
    {
        var d = Dog(5)
        check(d.legs == 4 && d.id == 5, "built")
    }

    check(opened == closed, "split derived constructor: closed")
    {
        var x   = Mover()
        var y   = Mover()
        var idy = y.id()
        x = y
        check(
            x.id() == idy && open_now() == 1,
            "assignment through the hand-written move constructor",
        )
    }

    check(opened == closed, "move assignment: closed")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
