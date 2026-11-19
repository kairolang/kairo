// In-place reordering and filling: swap (every pair, equal indices, both
// ends), reverse (every length from 0 to 40, whole slice and sub-ranges),
// rotate (every length from 0 to 9 and every amount from -2n to 2n, plus the
// isize extremes; a positive amount rotates left, an amount is taken modulo
// the length), fill and to_owned. Elements are i32, u8, string, a move-only
// instrumented class (swap, reverse and rotate move it and the live count
// returns to zero) and a copyable instrumented class (fill and to_owned
// count their duplications).
//
// Cases from libc++ test/std/algorithms/alg.modifying.operations/alg.reverse/
// Cases from libc++ test/std/algorithms/alg.modifying.operations/alg.rotate/
// Cases from libc++ test/std/algorithms/alg.modifying.operations/alg.fill/
// Cases from libc++ test/std/algorithms/alg.modifying.operations/alg.swap/
// Cases from Rust library/coretests/tests/slice.rs (swap, reverse, rotate_left, rotate_right, fill)
// Cases from Rust library/alloctests/tests/slice.rs (to_vec, rotate, reverse)

import self::inputs::inst::*
import std::io

fn ramp(n: usize) -> [i32] {
    var v: [i32]
    for var i: usize = 0; i < n; ++i {
        v.push(i as i32)
    }

    return v
}

fn swaps() {
    var v = ramp(6)
    var s: [i32;] = v
    s.swap(0, 5)
    check(v[0] == 5 && v[5] == 0 && v[1] == 1, "swap of both ends", 1)
    s.swap(2, 2)
    check(v[2] == 2, "swap of an element with itself", 2)
    s.swap(4, 1)
    check(v[1] == 4 && v[4] == 1, "swap with the larger index first", 3)
    s.swap(1, 4)
    check(v[1] == 1 && v[4] == 4, "swapping twice restores", 4)

    for var i: usize = 0; i < 6; ++i {
        for var j: usize = 0; j < 6; ++j {
            var w = ramp(6)
            var t: [i32;] = w
            t.swap(i, j)
            for var k: usize = 0; k < 6; ++k {
                var want = (if k == i => j else if k == j => i else => k)
                if w[k] != want as i32 {
                    fail("swap(i, j) moves exactly those two elements", 5)
                }
            }
        }
    }

    var one: [i32] = [9]
    var o: [i32;] = one
    o.swap(0, 0)
    check(one[0] == 9, "swap on one element", 6)

    var sv: [string] = ["a", "bb", "ccc"]
    var ss: [string;] = sv
    ss.swap(0, 2)
    check(sv[0] == "ccc" && sv[1] == "bb" && sv[2] == "a", "string swap", 7)

    {
        var iv = insts(4, 0, 1)
        var is: [Inst;] = iv
        is.swap(0, 3)
        is.swap(1, 2)
        is.swap(1, 1)
        check(iv[0].key() == 3 && iv[1].key() == 2 && iv[2].key() == 1 && iv[3].key() == 0, "inst swap", 8)
        check(iv[0].id == 3 && iv[3].id == 0, "inst swap carries the whole element", 9)
        check(LIVE == 4, "inst swap creates and destroys nothing net", 10)
    }

    check_clean("modify: swap", 11)
}

fn reverses() {
    for var n: usize = 0; n <= 40; ++n {
        var v = ramp(n)
        var s: [i32;] = v
        s.reverse()
        for var i: usize = 0; i < n; ++i {
            if v[i] != (n - 1 - i) as i32 {
                fail("reverse of a whole slice", 20)
            }
        }

        s.reverse()
        for var i: usize = 0; i < n; ++i {
            if v[i] != i as i32 {
                fail("reverse twice restores", 21)
            }
        }
    }

    var v = ramp(8)
    var s: [i32;] = v
    s[2..6].reverse()
    check(v[0] == 0 && v[1] == 1 && v[2] == 5 && v[5] == 2 && v[6] == 6 && v[7] == 7, "reverse of a middle range", 22)
    s[..3].reverse()
    check(v[0] == 5 && v[1] == 1 && v[2] == 0 && v[3] == 4, "reverse of a prefix", 23)
    s[6..].reverse()
    check(v[6] == 7 && v[7] == 6, "reverse of a suffix", 24)
    s[4..5].reverse()
    s[4..4].reverse()
    check(v[4] == 3, "reverse of one element and of an empty range", 25)

    var b: [u8] = [1, 2, 3]
    var bs: [u8;] = b
    bs.reverse()
    check(b[0] == 3 && b[1] == 2 && b[2] == 1, "u8 reverse", 26)
    var sv: [string] = ["a", "bb", "ccc", "dddd"]
    var ss: [string;] = sv
    ss.reverse()
    check(sv[0] == "dddd" && sv[3] == "a" && sv[1] == "ccc", "string reverse", 27)

    for var n: usize = 0; n <= 9; ++n {
        var iv = insts(n, 0, 1)
        var is: [Inst;] = iv
        is.reverse()
        for var i: usize = 0; i < n; ++i {
            if iv[i].key() != (n - 1 - i) as i64 {
                fail("inst reverse", 28)
            }
        }

        check(LIVE == n as i64, "inst reverse creates and destroys nothing net", 29)
    }

    check_clean("modify: reverse", 30)
}

/// The elements of `0..n` rotated left by `by`.
fn rotated(n: usize, by: usize) -> [i32] {
    var out: [i32]
    for var i: usize = 0; i < n; ++i {
        out.push(((i + by) % n) as i32)
    }

    return out
}

fn rotations() {
    for var n: usize = 0; n <= 9; ++n {
        for var a: isize = -2 * (n as isize); a <= 2 * (n as isize); ++a {
            var v = ramp(n)
            var s: [i32;] = v
            s.rotate(a)
            var left: usize = 0
            if n != 0 {
                left = (if a >= 0 => (a as usize) % n else => n - ((-a) as usize) % n)
                left %= n
            }

            var want = rotated(n, left)
            for var i: usize = 0; i < n; ++i {
                if v[i] != want[i] {
                    fail(f"rotate({a}) of {n} elements", 40)
                }
            }
        }
    }

    for var n: usize = 2; n <= 9; ++n {
        var hi = ramp(n)
        var sh: [i32;] = hi
        sh.rotate(isize::MAX)
        var want = rotated(n, (isize::MAX as usize) % n)
        for var i: usize = 0; i < n; ++i {
            if hi[i] != want[i] {
                fail("rotate(isize::MAX)", 41)
            }
        }

        var lo = ramp(n)
        var sl: [i32;] = lo
        sl.rotate(isize::MIN)
        var m = ((isize::MIN as usize) % n)
        var want2 = rotated(n, (n - m) % n)
        for var i: usize = 0; i < n; ++i {
            if lo[i] != want2[i] {
                fail("rotate(isize::MIN)", 42)
            }
        }
    }

    var v = ramp(10)
    var s: [i32;] = v
    s[2..8].rotate(1)
    check(v[1] == 1 && v[2] == 3 && v[7] == 2 && v[8] == 8, "rotate of a sub-range stays inside it", 43)
    s[..4].rotate(-1)
    check(v[0] == 4 && v[1] == 0 && v[2] == 1 && v[3] == 3, "rotate right of a prefix", 44)
    s[8..].rotate(1)
    check(v[8] == 9 && v[9] == 8, "rotate of a suffix", 45)

    var sv: [string] = ["a", "b", "c", "d", "e"]
    var ss: [string;] = sv
    ss.rotate(2)
    check(sv[0] == "c" && sv[1] == "d" && sv[2] == "e" && sv[3] == "a" && sv[4] == "b", "string rotate left", 46)
    ss.rotate(-2)
    check(sv[0] == "a" && sv[4] == "e", "string rotate right undoes it", 47)

    for var n: usize = 0; n <= 40; n += 1 {
        for var a: isize = -(n as isize); a <= (n as isize); a += 7 {
            var iv = insts(n, 0, 1)
            var is: [Inst;] = iv
            is.rotate(a)
            var left: usize = 0
            if n != 0 {
                left = (if a >= 0 => (a as usize) % n else => n - ((-a) as usize) % n)
                left %= n
            }

            for var i: usize = 0; i < n; ++i {
                if iv[i].key() != ((i + left) % n) as i64 {
                    fail("inst rotate", 48)
                }
            }

            if LIVE != n as i64 {
                fail("inst rotate creates and destroys nothing net", 49)
            }
        }
    }

    check_clean("modify: rotate", 50)
}

fn fills() {
    var v = ramp(5)
    var s: [i32;] = v
    s.fill(7)
    check(v[0] == 7 && v[4] == 7 && v[2] == 7, "fill of a whole slice", 60)
    s[1..3].fill(0)
    check(v[0] == 7 && v[1] == 0 && v[2] == 0 && v[3] == 7, "fill of a sub-range", 61)
    s[..0].fill(1)
    s[5..].fill(1)
    check(v[0] == 7 && v[4] == 7, "fill of an empty range writes nothing", 62)
    var none: [i32]
    var e: [i32;] = none
    e.fill(3)
    check(e.size() == 0, "fill of an empty slice", 63)
    var one: [i32] = [1]
    var o: [i32;] = one
    o.fill(-4)
    check(one[0] == -4, "fill of one element", 64)

    var b: [u8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33]
    var bs: [u8;] = b
    bs.fill(255)
    var all = true
    for var i: usize = 0; i < b.size(); ++i {
        all = all && b[i] == 255
    }

    check(all, "u8 fill of 33 elements", 65)
    bs[10..20].fill(0)
    check(b[9] == 255 && b[10] == 0 && b[19] == 0 && b[20] == 255, "u8 fill of a sub-range", 66)

    var sv: [string] = ["a", "b", "c"]
    var ss: [string;] = sv
    ss.fill("long string value that does not fit inline")
    check(sv[0] == sv[1] && sv[1] == sv[2] && sv[2].size() == 42, "string fill", 67)
    sv[0] += "!"
    check(sv[1].size() == 42, "filled strings are independent copies", 68)

    {
        var d: [Dup]
        for var i: i64 = 0; i < 4; ++i {
            d.push(Dup(i))
        }

        var ds: [Dup;] = d
        var copies0 = COPIES
        ds.fill(Dup(42))
        check(COPIES - copies0 == 4, "fill makes one copy per element", 69)
        check(d[0].k == 42 && d[3].k == 42, "copyable instrumented fill", 70)
        check(LIVE == 4, "fill destroys what it overwrote and leaks nothing", 71)
        ds[..0].fill(Dup(1))
        check(COPIES - copies0 == 4 && LIVE == 4, "fill of an empty range copies nothing", 72)
    }

    check_clean("modify: fill", 73)
}

fn owned() {
    var v: [i32] = [1, 2, 3]
    var s: [i32;] = v
    var o = s.to_owned()
    check(o.size() == 3 && o[0] == 1 && o[2] == 3, "to_owned copies the elements", 80)
    o[0] = 100
    s[1] = 200
    check(v[0] == 1 && o[1] == 2, "to_owned is independent of the original", 81)
    var part = s[1..3].to_owned()
    check(part.size() == 2 && part[0] == 200, "to_owned of a sub-range", 82)
    var none: [i32]
    var e: [i32;] = none
    check(e.to_owned().size() == 0, "to_owned of an empty slice", 83)
    var one: [i32] = [5]
    var os: [i32;] = one
    check(os.to_owned()[0] == 5, "to_owned of one element", 84)
    const c: [const i32;] = s
    check(c.to_owned().size() == 3 && c[1..].to_owned()[0] == 200, "to_owned of a const slice", 85)

    var sv: [string] = ["x", "yy"]
    var ss: [string;] = sv
    var so = ss.to_owned()
    so[0] += "!"
    check(sv[0] == "x" && so[0] == "x!" && so[1] == "yy", "string to_owned", 86)

    {
        var d: [Dup]
        for var i: i64 = 0; i < 3; ++i {
            d.push(Dup(i))
        }

        var ds: [Dup;] = d
        var copies0 = COPIES
        {
            var out = ds.to_owned()
            check(out.size() == 3 && out[2].k == 2, "copyable instrumented to_owned", 87)
            check(COPIES - copies0 == 3 && LIVE == 6, "to_owned makes one copy per element", 88)
        }

        check(LIVE == 3, "the owned copy is destroyed with its vector", 89)
    }

    check_clean("modify: to_owned", 90)
}

fn main() -> i32 {
    swaps()
    reverses()
    rotations()
    fills()
    owned()
    io::println("modify ok")
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: modify ok
