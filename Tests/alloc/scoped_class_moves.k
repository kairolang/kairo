// Moving and assigning objects of `@set_scoped_allocator(A)` classes: the
// arena moves with the object. Return by value, pass by value, a move into
// a vector (and the vector's growth), a hand-written `@move` constructor
// (which takes over the source's arena before its body moves the fields),
// `a = b` on two live objects, `a = T()`, and an assignment into a
// moved-from variable. Every arena is closed exactly once (the fixture
// aborts on a second close), the moved object keeps allocating in the arena
// it brought, and no block of an arena reaches the global allocator.
import builtin::base::alloc::*
import inputs::counting_arenas::*
import std::io::println

static stray: i32 = 0

class G {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
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
        return System::alloc_zeroed(size, align)
    }
}

@set_global_allocator(G)

@set_scoped_allocator(Arenas)
class Log {
    pub var text: string
    fn Log(self) {
        self.text.push_str(
            "a log, long enough to leave the small buffer ...........................",
        )
    }

    fn add(self) {
        self.text.push_str(
            "more ...................................................................",
        )
    }

    fn id(const self) -> usize {
        return cur
    }
}

static moves: i32 = 0

@set_scoped_allocator(Arenas)
class Mover {
    pub var text: string
    fn Mover(self) {
        self.text.push_str(
            "a mover, long enough to leave the small buffer .........................",
        )
    }

    @move
    fn Mover(self, other: Self) {
        moves += 1
        self.text = other.text
    }

    fn add(self) {
        self.text.push_str(
            "more ...................................................................",
        )
    }

    fn id(const self) -> usize {
        return cur
    }
}

fn make() -> Log {
    var l = Log()
    l.add()
    return l
}

fn take(l: Log) -> usize {
    var mine = l.id()
    l.add()
    return mine
}

fn pass(m: Mover) -> Mover {
    return m
}

fn main() -> i32 {
    {
        var a = make()
        check(open_now() == 1, "returned by value with its arena")
        var id = a.id()
        a.add()
        check(
            served[id - 1] >= 3,
            "the returned object allocates in the arena it brought",
        )

        check(take(a) == id, "passed by value with its arena")
    }

    check(opened == closed, "return and pass: every arena closed once")

    {
        var v: [Log]
        for var i = 0; i < 5; i += 1 {
            v.push(Log())
        }

        check(
            open_now() == 5,
            "five objects moved into a vector keep their arenas",
        )

        for var i: usize = 0; i < 5; i += 1 {
            v[i].add()
        }
    }

    check(opened == closed, "the vector: every arena closed once")

    {
        var m  = Mover()
        var id = m.id()
        var n  = pass(m)
        check(moves > 0, "the hand-written move constructor ran")
        check(n.id() == id, "the move constructor took the source's arena")
        n.add()
        check(
            open_now() == 1,
            "the arena the move constructor made in its place is gone",
        )
    }

    check(opened == closed, "the move constructor: every arena closed once")

    {
        var x = Log()
        var y = Log()
        x.add()
        y.add()
        var idy = y.id()
        x = y
        check(open_now() == 1, "x's old arena closed once by the assignment")
        check(x.id() == idy, "x took y's arena")
        x.add()
        x = Log()
        check(
            open_now() == 1,
            "a = T(): the old arena closed, the new one kept",
        )

        x.add()
        var z = x
        x = Log()
        x.add()
        z.add()
        check(open_now() == 2, "an assignment into a moved-from variable")
    }

    check(opened == closed, "assignments: every arena closed once")
    check(stray == 0, "no block of an arena reached the global allocator")
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
