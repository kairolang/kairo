// The primitives meet the base interfaces as bounds, which is how the
// containers and string reach them: Hash, Default, Append, ToString,
// FromStr and Copyable through a generic function each, for an unsigned, a
// signed, a pointer-sized, a bool, a char and a float type.

import std::io

fn <T impl Hash> hashed(const v: T) -> u64 {
    var h = Hasher(7)
    v.hash(&h)
    return h.finish()
}

fn <T impl Default> zero() -> T = T::make_default()

fn <T impl Append> appended(const v: T) -> string {
    var s = string()
    s.push_str("[")
    v.append_to(&s)
    s.push_str("]")
    return s
}

fn <T impl ToString> text(const v: T) -> string = v as string

fn <T impl FromStr> parsed(const s: string) -> T? {
    return T::from_str(s)
}

fn <T impl Copyable> twice(const v: T) -> T = copy(v)

fn main() -> i32 {
    var bad = 0
    if hashed(5u64) != hashed(5u64) || hashed(5u64) == hashed(6u64) {
        bad += 1
    }

    // A signed value hashes as its sign-extended bits.
    if hashed(-1i8) != hashed(0xFFFFFFFFFFFFFFFFu64) || hashed(3usize) != hashed(3u64) {
        bad += 2
    }

    if hashed(true) != hashed(1u64) || hashed('a') != hashed(97u64) {
        bad += 4
    }

    if zero<u64>() != 0 || zero<i8>() != 0 || zero<usize>() != 0 || zero<f64>() != 0.0 || zero<char>() != '\x00' {
        bad += 8
    }

    io::println(f"{appended(42u64)} {appended(-7i8)} {appended(9usize)} {appended(false)} {appended('z')} {appended(2.5)}")
    io::println(f"{text(42u64)} {text(-7i8)} {text(9usize)} {text(true)} {text('z')} {text(0.1)}")
    var a = parsed<u64>("42") ?? 0
    var b = parsed<i8>("-7") ?? 0
    var c = parsed<usize>("9") ?? 0
    var d = parsed<bool>("true") ?? false
    var e = parsed<char>("z") ?? '\x00'
    var f = parsed<f64>("2.5") ?? 0.0
    if a != 42 || b != -7 || c != 9 || !d || e != 'z' || f != 2.5 {
        bad += 16
    }

    if parsed<u8>("256")? || parsed<bool>("yes")? {
        bad += 32
    }

    if twice(3u64) != 3 || twice('q') != 'q' || twice(1.5) != 1.5 {
        bad += 64
    }

    io::println(f"bad {bad}")
    return bad
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      [42] [-7] [9] [false] [z] [2.5]
// CHECK-NEXT: 42 -7 9 true z 0.1
// CHECK-NEXT: bad 0
