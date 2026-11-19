// `peek` returns the address of the item the chain holds, whatever the
// item's nullable looks like: a number with a tag beside it, a pointer whose
// null is the tag, a string, a tuple, a one-byte value. Each chain starts at
// a value that is not zero, peeks it, and gets the same value from `next`.

import std::iter::*
import std::io

var failed: i32 = 0

fn hold(const label: string, cond: bool) {
    if !cond {
        failed += 1
        io::println(f"FAILED {label}")
    }
}

fn wide() -> yield i64 {
    yield 0x1122334455667788
    yield -5
}

fn narrow() -> yield u8 {
    yield 200
    yield 7
}

fn words() -> yield string {
    yield "a string long enough to live on the heap, not in the handle"
    yield "fig"
}

fn pairs() -> yield (u8, i64) {
    yield (9, 123456789012)
    yield (1, -1)
}

fn main() -> i32 {
    var a = iter(wide()).peekable()
    var *pa? = a.peek()
    hold("i64 peek", pa? && *unwrap!(pa) == 0x1122334455667788)
    hold("i64 next", (a.next() ?? 0) == 0x1122334455667788)
    var *pa2? = a.peek()
    hold("i64 second", pa2? && *unwrap!(pa2) == -5 && (a.next() ?? 0) == -5 && !a.peek()?)

    var b = iter(narrow()).peekable()
    var *pb? = b.peek()
    hold("u8 peek", pb? && *unwrap!(pb) == (200 as u8))
    hold("u8 next", (b.next() ?? (0 as u8)) == (200 as u8))
    var *pb2? = b.peek()
    hold("u8 second", pb2? && *unwrap!(pb2) == (7 as u8))

    var nums: [i32] = [41, 42, 43]
    // A slice of its own: the generator keeps its receiver by address, and
    // the slice a vector converts to for the call would end with this line.
    var view: [const i32;] = nums
    var c = iter(view.iter()).peekable()
    var **pc? = c.peek()
    hold("pointer peek", pc? && **unwrap!(pc) == 41)
    var *first? = c.next()
    hold("pointer next", first? && *unwrap!(first) == 41)
    var **pc2? = c.peek()
    hold("pointer second", pc2? && **unwrap!(pc2) == 42)

    var d = iter(words()).peekable()
    var *pd? = d.peek()
    hold("string peek", pd? && unwrap!(pd)->size() == 59 && unwrap!(pd)->starts_with("a string long"))
    var w? = d.next()
    hold("string next", w? && unwrap!(w).size() == 59)
    var *pd2? = d.peek()
    hold("string second", pd2? && *unwrap!(pd2) == "fig")

    var e = iter(pairs()).peekable()
    var *pe? = e.peek()
    hold("tuple peek", pe? && unwrap!(pe)->0 == (9 as u8) && unwrap!(pe)->1 == 123456789012)
    var t? = e.next()
    hold("tuple next", t? && unwrap!(t).1 == 123456789012)
    var *pe2? = e.peek()
    hold("tuple second", pe2? && unwrap!(pe2)->1 == -1)
    return failed
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo -O2 %s -o %t.O2.exe --cache-dir %t.d
// RUN: %t.O2.exe
