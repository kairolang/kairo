// `string::from_utf8` returns null for bytes that are not UTF-8;
// `string::try_from_utf8` returns the string or raises a Utf8Error naming the
// lead byte of the first ill-formed sequence and why it is ill-formed.

import std::io

static FAILS: i32 = 0

fn ck(ok: bool, what: string) {
    if !ok {
        io::println(f"FAIL {what}")
        FAILS += 1
    }
}

// "kind@at" for the bytes, "ok:<text>" when they are UTF-8.
fn why(const b: [const u8;]) -> string {
    try {
        var s = string::try_from_utf8(b)
        return f"ok:{s}"
    } catch e: Utf8Error {
        return f"{e.kind as u8}@{e.at}"
    }
}

fn kind_at(k: Utf8ErrorKind, at: u32) -> string {
    return f"{k as u8}@{at}"
}

fn main() -> i32 {
    var ok: [u8] = [0x68, 0xc3, 0xa9, 0x6c, 0x6c, 0x6f] // "héllo"
    var s? = string::from_utf8(ok)
    ck(s? && s == "héllo", "from_utf8 accepts UTF-8")
    ck(why(ok) == "ok:héllo", f"try_from_utf8 accepts UTF-8: {why(ok)}")
    var none: [u8] = []
    ck(why(none) == "ok:", "the empty input is the empty string")

    // A continuation byte where a sequence starts.
    var lone: [u8] = [0x61, 0x62, 0x80]
    ck(!string::from_utf8(lone)?, "from_utf8 rejects a lone continuation")
    ck(why(lone) == kind_at(Utf8ErrorKind::InvalidLead, 2), f"lone: {why(lone)}")
    // C0 and F5 start nothing.
    var c0: [u8] = [0xc0, 0x80]
    ck(why(c0) == kind_at(Utf8ErrorKind::InvalidLead, 0), f"c0: {why(c0)}")
    var f5: [u8] = [0x61, 0xf5, 0x80, 0x80, 0x80]
    ck(why(f5) == kind_at(Utf8ErrorKind::InvalidLead, 1), f"f5: {why(f5)}")

    // The input ends inside a sequence.
    var cut: [u8] = [0x61, 0xe2, 0x82]
    ck(!string::from_utf8(cut)?, "from_utf8 rejects a truncated sequence")
    ck(why(cut) == kind_at(Utf8ErrorKind::Truncated, 1), f"cut: {why(cut)}")
    var cut4: [u8] = [0xf0, 0x9f, 0x98]
    ck(why(cut4) == kind_at(Utf8ErrorKind::Truncated, 0), f"cut4: {why(cut4)}")

    // A lead byte whose next byte does not continue it: a plain byte, an
    // overlong form, a surrogate, a value above U+10FFFF.
    var plain: [u8] = [0x61, 0x61, 0xe2, 0x41, 0x41]
    ck(why(plain) == kind_at(Utf8ErrorKind::InvalidContinuation, 2), f"plain: {why(plain)}")
    var over: [u8] = [0xe0, 0x80, 0x80]
    ck(why(over) == kind_at(Utf8ErrorKind::InvalidContinuation, 0), f"overlong: {why(over)}")
    var surr: [u8] = [0x7a, 0xed, 0xa0, 0x80]
    ck(why(surr) == kind_at(Utf8ErrorKind::InvalidContinuation, 1), f"surrogate: {why(surr)}")
    var high: [u8] = [0xf4, 0x90, 0x80, 0x80]
    ck(why(high) == kind_at(Utf8ErrorKind::InvalidContinuation, 0), f"above U+10FFFF: {why(high)}")
    // A truncated sequence whose present byte is already wrong.
    var bad_cut: [u8] = [0xe2, 0x41]
    ck(why(bad_cut) == kind_at(Utf8ErrorKind::InvalidContinuation, 0), f"bad cut: {why(bad_cut)}")

    // The first ill-formed sequence is the one reported.
    var two: [u8] = [0xc3, 0xa9, 0xff, 0xe2]
    ck(why(two) == kind_at(Utf8ErrorKind::InvalidLead, 2), f"first of two: {why(two)}")

    var msg = try string::try_from_utf8(cut) catch e: Utf8Error => e.op panic()
    ck(msg == "invalid UTF-8: truncated sequence at byte 1", f"message: {msg}")
    var msg2 = try string::try_from_utf8(lone) catch e: Utf8Error => e.op panic()
    ck(msg2 == "invalid UTF-8: invalid lead byte at byte 2", f"message: {msg2}")

    io::println(f"done, {FAILS} failures")
    return FAILS
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: done, 0 failures
