// A cast reads a nullable as its value where the program has proven it
// non-null on every path to the cast, in two shapes:
//
//   - an `else if` condition that tests `length?` and then reads
//     `length` (`length? && length > 0`): the cast in its body;
//   - a loop that leaves on null (`if !d? { break }`) and then casts `d`,
//     or matches on it, with no `case null` arm or with a `case null`
//     first arm that is never taken.
//
// Each check prints, so a wrong value shows which one.

import std::io::println

fn get(n: i64) -> i64? {
    if n > 0 {
        return n
    }

    return null
}

fn digit(c: u8) -> i32? {
    if c >= 48 as u8 && c <= 57 as u8 {
        return c - 48 as u8
    }

    return null
}

fn body_len(length: i64?, chunked: bool) -> usize {
    if chunked {
        return 1
    } else if length? && length > 0 {
        var len = length as usize
        return len
    }

    return 0
}

fn parse(t: string) -> usize {
    var x: usize = 0
    var i: usize = 0
    while i < t.size() {
        var d? = digit(t.data()[i])
        if !d? {
            break
        }

        x = x * 10 + d as usize
        i += 1
    }

    return x
}

fn last_digit(t: string) -> usize {
    var x: usize = 99
    var i: usize = 0
    while i < t.size() {
        var d? = digit(t.data()[i])
        if !d? {
            break
        }

        x = d as usize
        i += 1
    }

    return x
}

fn count_zeros(t: string) -> i32 {
    var n        = 0
    var i: usize = 0
    while i < t.size() {
        var d? = digit(t.data()[i])
        if !d? {
            break
        }

        match d {
            case 0 {
                n += 1
            } default { }
        }

        i += 1
    }

    return n
}

fn count_digits(t: string) -> i32 {
    var n        = 0
    var i: usize = 0
    while i < t.size() {
        var d? = digit(t.data()[i])
        if !d? {
            break
        }

        match d {
            case null {
                n += 100
            } case 0 {
                n += 10
            } default {
                n += 1
            }
        }

        i += 1
    }

    return n
}

fn main() -> i32 {
    println(
        f"body_len {body_len(get(5), false)} {body_len(get(0), false)} {body_len(get(5), true)}",
    )

    println(f"parse {parse("307x9")} {parse("x")} {parse("42")}")
    println(f"last_digit {last_digit("58x1")} {last_digit("x")}")
    println(f"count_zeros {count_zeros("10020x0")} {count_zeros("7")}")
    println(f"count_digits {count_digits("1023a")} {count_digits("")}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: body_len 5 0 1
// OUT-NEXT: parse 307 0 42
// OUT-NEXT: last_digit 8 99
// OUT-NEXT: count_zeros 3 0
// OUT-NEXT: count_digits 13 0
