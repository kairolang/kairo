// What an f-string hands back: an owned string whether the text stayed in the
// formatter's inline storage, spilled to the heap (where the string takes the
// formatter's block over), is empty, or holds non-ASCII text; the result
// grows and is freed like any other heap string.

import std::io::*

fn check(const s: string, bytes: usize, cps: usize, what: string) -> i32 {
    if s.size() != bytes || s.codepoints() != cps {
        println(f"FAIL {what}: {s.size()} bytes, {s.codepoints()} codepoints")
        return 1
    }

    return 0
}

fn main() -> i32 {
    var bad = 0
    var word = "abcdefghij"
    var n: i32 = 42

    var small = f"{word}-{n}"
    bad += check(small, 13, 13, "inline")
    small.push_str("!")
    bad += check(small, 14, 14, "inline then push")

    var empty = f"{""}"
    bad += check(empty, 0, 0, "empty")
    empty.push_str(word)
    bad += check(empty, 10, 10, "empty then push")

    // 15 holes of 10 bytes: past the 128 inline bytes.
    var big = f"{word}{word}{word}{word}{word}{word}{word}{word}{word}{word}{word}{word}{word}{word}{word}"
    bad += check(big, 150, 150, "spilled")
    for var i = 0; i < 100; i++ {
        big.push_str(word)
    }
    bad += check(big, 1150, 1150, "spilled then grown")
    if !big.ends_with(word) || !big.starts_with("abcdefghijabc") {
        println("FAIL spilled text")
        bad += 1
    }

    var accent = "héllo wörld ☃"
    var mixed = f"<{accent}|{n}>"
    bad += check(mixed, accent.size() + 5, accent.codepoints() + 5, "non-ASCII inline")
    var wide = f"{accent}{accent}{accent}{accent}{accent}{accent}{accent}{accent}{accent}{accent}"
    bad += check(wide, accent.size() * 10, accent.codepoints() * 10, "non-ASCII spilled")
    println(mixed)

    // The codepoint count the formatter hands over is the string's own: a
    // char hole, a padded non-ASCII hole and a float, recounted by decoding.
    var c: char = 0xe9 as char
    var e = "\u00e9"
    var x = 1.5
    var holes = f"{c}{c}|{e:>5}|{x}|{c}"
    var seen: usize = 0
    for ch in holes {
        seen += 1
    }

    bad += check(holes, 18, seen, "char, padded and float holes")
    println(holes)

    if bad == 0 {
        println("ok")
    }

    return bad
}

// CHECK: <héllo wörld ☃|42>
// CHECK-NEXT: éé|    é|1.5|é
// CHECK-NEXT: ok

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
