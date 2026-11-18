// A write through the mutable `[]` keeps codepoints() right. The
// operator hands out a raw byte place and never sees the store, so it
// marks the count stale and codepoints() counts the bytes (string.k,
// CPS_STALE). Each write below changes what the bytes encode: an ASCII
// byte becomes a lead byte (still one codepoint), then the byte after it
// a continuation (two bytes, one codepoint), then ASCII again, then a
// continuation where a codepoint started. A stale count survives `+`
// and `+=` on either side, and subslice() of a stale string counts its
// own bytes.

fn main() -> i32 {
    var s = "abcd"
    var r = 0
    if s.codepoints() == 4 { r += 1 }
    s[1] = 0xC3
    if s.codepoints() == 4 { r += 2 }
    s[2] = 0xA9                       // "aéd"
    if s.codepoints() == 3 { r += 4 }
    s[2] = 0x63
    if s.codepoints() == 4 { r += 8 }
    s[1] = 0x80
    if s.codepoints() == 3 { r += 16 }
    var t = s + s                     // both stale
    if t.codepoints() == 6 { r += 32 }
    var u = "xy"
    u += s                            // fresh += stale
    s += "z"                          // stale += fresh
    if (u.codepoints() == 5) && (s.codepoints() == 4) { r += 64 }
    var v = s.subslice(1, 3)          // 0x80 'c' 'd': two
    if v.codepoints() == 2 { r += 128 }
    return if r == 255 => 0 else => r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
