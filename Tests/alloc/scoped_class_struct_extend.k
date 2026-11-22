import inputs::counting_arenas::*
import inputs::scoped_class_ext::*
import inputs::scoped_class_rec::*
// `@set_scoped_allocator(A)` on a struct, which has named methods only
// through `extend`: the struct is built by an initializer that names none
// of the arena's fields, and the methods of an `extend` in the same file, in
// another file, and of a generic `extend` of a generic class (here and in
// another file) all allocate in the object's arena. A static method of an
// `extend` opens none.
import std::io::println

extend Rec {
    fn fill(self) -> usize {
        self.text.push_str(
            "from this file ........................................................",
        )

        return cur
    }

    static fn outside() -> usize {
        return cur
    }

    fn twice(const self) -> i32 = self.n * 2
}

extend <T> Box<T> {
    fn add_here(self, v: T) -> usize {
        self.items.push(v)
        return cur
    }
}

fn main() -> i32 {
    {
        var r = Rec { n: 21, text: "" }
        check(open_now() == 1, "an initializer builds the arena too")
        var id = r.fill()
        check(
            id != 0 && served[id - 1] > 0,
            "an extend in this file allocates in the arena",
        )

        var s0 = served[id - 1]
        check(
            r.fill_far() == id && served[id - 1] > s0,
            "an extend in another file allocates in the arena",
        )

        check(
            Rec::outside() == 0,
            "a static method of an extend opens no arena",
        )

        check(r.twice() == 42, "an expression-bodied extension method")
        check(cur == 0, "no arena current between calls")
    }

    check(opened == closed, "the struct's arena closed once")

    {
        var b         = Box<i64>()
        var id: usize = 0
        for var i: i64 = 0; i < 40; i += 1 {
            b.add(i)
            id = b.add_here(i)
            check(
                b.add_far(i) == id,
                "a generic extend in another file opens the same arena",
            )
        }

        check(b.items.size() == 120, "every push landed")
        check(
            id != 0 && served[id - 1] > 0,
            "a generic extend allocates in the arena",
        )
    }

    check(opened == closed, "the generic class's arena closed once")
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
