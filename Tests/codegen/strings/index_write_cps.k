// codepoints() stays right through every edit that changes what the bytes
// encode. A string has no writable `[]`: each edit goes through a mutator,
// which keeps the count (string.k: a heap string's count word is exact).
// Each step below changes the mix: an ASCII string gains a two-byte char,
// a three-byte one in the middle, loses a char from the middle and from
// the end, is cut back to ASCII. The count survives `+` and `+=` on either
// side, a non-ASCII view appended is counted as it is copied, and a view
// of an edited string counts its own bytes.

fn main() -> i32 {
    var s = "abcd".to_owned()
    var r = 0
    if s.codepoints() == 4 { r += 1 }
    s.insert(1, "é")                  // "aébcd"
    if (s.codepoints() == 5) && (s.size() == 6) { r += 2 }
    s.insert(3, "€")                  // "aé€bcd"
    if (s.codepoints() == 6) && (s.size() == 9) { r += 4 }
    s.remove_range(1..3)              // "a€bcd"
    if (s.codepoints() == 5) && (s.size() == 7) && (s == "a€bcd") { r += 8 }
    var last = s.pop() ?? ' '         // 'd'
    if (s.codepoints() == 4) && (last == 'd') { r += 16 }
    var t = s.copy() + s              // "a€bca€bc"
    if t.codepoints() == 8 { r += 32 }
    var u = "xy"
    u += s                            // literal += heap
    s += "z€"                         // heap += literal
    s.push_str("ñandú"[0..3])         // a non-ASCII view: "ña"
    if (u.codepoints() == 6) && (s.codepoints() == 8) { r += 64 }
    var v = s[1..6]                   // "€bc": a view, two of it ASCII
    if (v.codepoints() == 3) && v.is_view() { r += 128 }
    s.truncate(1)                     // "a": ASCII again
    if (s.codepoints() == 1) && s.is_ascii() { r += 256 }
    return if r == 511 => 0 else => r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
