import inputs::counting_arenas::*
// Fields an `eval if` adds to a `@set_scoped_allocator(A)` class, one folded
// before names resolve and one decided once types are (a type fact), are
// laid out between the arena's two fields: their blocks come from the arena
// and go back to it when the object is destroyed.
import std::io::println

eval WIDE: bool = true

@set_scoped_allocator(Arenas)
class Branchy {
    var a: string
    eval if WIDE {
        var b: string
    }

    var c: i32 = 0
    eval if sizeof i32 == 4 {
        var d: string
    }

    fn fill(self) -> usize {
        self.a.push_str(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )

        self.b.push_str(
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        )

        self.d.push_str(
            "ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        )

        return cur
    }
}

fn main() -> i32 {
    var id: usize = 0
    {
        var x = Branchy()
        id = x.fill()
        check(
            id != 0 && served[id - 1] == 3,
            "the three strings came from the arena",
        )
    }

    check(
        freedn[id - 1] == 3,
        "and went back to it: every field is inside the pair",
    )

    check(opened == 1 && closed == 1, "the arena closed once")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
