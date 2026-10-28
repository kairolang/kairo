// A `char` literal holds any Unicode scalar value (primitives.mdx, Char:
// `var cjk = '漢'`), and converts to its code point with `as`. Found while
// writing run_int_edges.k, which reaches these code points through
// integers instead.
//
// XFAIL: *
// Ticket "[Codegen] A non-ASCII char literal is spelled as a narrow C++
// character literal" (2026-10-28). EmitIR writes '漢' as the C++ literal
// '漢' (type char / int, multi-byte) where char is char32_t, so clang
// refuses it: CL001E "character too large for enclosing character literal
// type". ASCII literals ('A') build only because a narrow literal of them
// happens to convert. The spelling must be U'漢' (or the code point as a
// char32_t constant). When it XPASSes, delete the XFAIL.

import std::io::println

fn main() -> i32 {
    var bad = 0;
    if ('漢' as u32) != 0x6F22 { println("han"); bad += 1; }
    if ('é' as u32) != 0xE9 { println("e-acute"); bad += 1; }
    if ('📣' as u32) != 0x1F4E3 { println("megaphone"); bad += 1; }
    var c: char = '漢';
    if (c as u8) != 0x22 { println("han as u8"); bad += 1; }
    println(f"bad {bad}");
    return bad;
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: bad 0
