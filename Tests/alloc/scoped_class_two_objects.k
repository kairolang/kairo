import inputs::counting_arenas::*
// Two live objects of a `@set_scoped_allocator(A)` class, used in turn: each
// method allocates in its own object's arena, a method of one calling a
// method of the other (and that one calling back) switches to the callee's
// arena for the call and back again, and no arena is current between calls.
import std::io::println

@set_scoped_allocator(Arenas)
class Peer {
    pub var text: string
    pub var hits: i32    = 0

    fn id(const self) -> usize {
        return cur
    }

    fn add(self, const s: string) {
        self.text.push_str(s)
        self.text.push_str(
            "........................................................",
        )

        self.hits += 1
    }

    fn poke(self, other: *Peer, back: bool) {
        var mine = cur
        self.add("poke")
        other->add("poked")
        check(cur == mine, "back in the caller's arena after the call")
        if back {
            other->poke(&self, false)
            check(cur == mine, "back in the caller's arena after the call back")
        }

        self.add("poke again")
    }
}

fn main() -> i32 {
    {
        var a  = Peer()
        var b  = Peer()
        var ia = a.id()
        var ib = b.id()
        check(ia != ib && ia != 0 && ib != 0, "two objects, two arenas")
        check(cur == 0, "no arena current between calls")
        a.add("first")
        check(
            served[ia - 1] > 0 && served[ib - 1] == 0,
            "the first object's arena served it",
        )

        b.add("second")
        check(served[ib - 1] > 0, "the second object's arena served it")
        check(cur == 0, "no arena current between calls")
        var sa = served[ia - 1]
        var sb = served[ib - 1]
        a.poke(&b, true)
        check(
            served[ia - 1] > sa && served[ib - 1] > sb,
            "each arena served its own object",
        )

        check(a.hits == 4 && b.hits == 4, "every call ran")
        check(cur == 0, "no arena current between calls")
    }

    check(opened == 2 && closed == 2, "two arenas, closed once each")
    check(
        freedn[0] == served[0] && freedn[1] == served[1],
        "every block went back to its arena",
    )

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
