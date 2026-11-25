// A u256 / u512 is laid out as the target's C++ `_BitInt(256)` / `_BitInt(512)`:
// its size is its width and its alignment is clang's, 8 on x86_64. So a
// nullable or a record holding one has clang's size, and a function that
// returns `null` as a `u256?` passes the layout checks the C++ side makes.

struct HoldsU256 {
    var tag: u8
    var v:   u256
}

struct HoldsU512 {
    var tag: u8
    var v:   u512
}

fn none256() -> u256? {
    return null
}

fn none512() -> u512? {
    return null
}

fn some256(v: u256) -> u256? {
    return v
}

fn main() -> i32 {
    var al: usize = if sizeof usize == 8 => 8 else => 4
    var bad       = 0
    if alignof (u256) != al {
        bad = bad + 1
    }

    if alignof (u512) != al {
        bad = bad + 2
    }

    if sizeof (u256?) != 32 + al {
        bad = bad + 4
    }

    if sizeof (u512?) != 64 + al {
        bad = bad + 8
    }

    if sizeof (HoldsU256) != 32 + al {
        bad = bad + 16
    }

    if sizeof (HoldsU512) != 64 + al {
        bad = bad + 32
    }

    var a? = none256()
    var b? = none512()
    var c? = some256(7)
    if a != null || b != null {
        bad = bad + 64
    }

    if c == null {
        bad = bad + 128
    }

    return bad
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d %t.e
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s --target=x86_64-linux-musl -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s --target=x86_64-linux-musl -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe
