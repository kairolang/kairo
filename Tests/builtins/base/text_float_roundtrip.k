// f64 and f32 through text and back: 10^7 seeded random bit patterns of
// each, every one of which must read back as the same bits (a NaN as a
// NaN). Every 16th value also goes through the exact parser alone, and the
// longest text seen must be exactly the stated maximum.

import std::io::*
import self::inputs::numtext_support::*

fn main() -> i32 {
    var rng = Rng { s: 0xDEADBEEFCAFEF00D }
    var buf: [u8; 32]
    var unsafe *b = unsafe &buf[0]
    var err = ParseError { at: 0, kind: ParseErrorKind::None }

    // Case 1: f64.
    var longest: usize = 0
    for var i: i32 = 0; i < ROUNDS; ++i {
        var bits = rng_next(&rng)
        var v    = __builtin_bitcast<f64, u64>(bits)
        var n    = f64_to_text(v, b)
        if n > longest {
            longest = n
        }

        var back = parse_f64(b, n, &err).to_bits()
        var nan  = (bits & 0x7FFFFFFFFFFFFFFF) > 0x7FF0000000000000
        var ok   = if nan => (back & 0x7FFFFFFFFFFFFFFF) > 0x7FF0000000000000 else => back == bits
        if !ok || err.kind != ParseErrorKind::None {
            fail(1, f"f64 bits {bits:#x} -> '{show(b, n)}' -> {back:#x} kind {err.kind as u8}")
            break
        }

        if (i & 15) == 0 && !nan {
            var slow = parse_f64_exact(b, n, &err).to_bits()
            if slow != bits || err.kind != ParseErrorKind::None {
                fail(1, f"f64 bits {bits:#x} -> '{show(b, n)}' -> exact path {slow:#x} kind {err.kind as u8}")
                break
            }
        }
    }

    if longest != F64_TEXT_MAX {
        fail(2, f"longest f64 text {longest}, stated {F64_TEXT_MAX}")
    }

    // Case 3: f32.
    longest = 0
    for var i: i32 = 0; i < ROUNDS; ++i {
        var bits = rng_next(&rng) as u32
        var v    = __builtin_bitcast<f32, u32>(bits)
        var n    = f32_to_text(v, b)
        if n > longest {
            longest = n
        }

        var back = parse_f32(b, n, &err).to_bits()
        var nan  = (bits & 0x7FFFFFFF) > 0x7F800000
        var ok   = if nan => (back & 0x7FFFFFFF) > 0x7F800000 else => back == bits
        if !ok || err.kind != ParseErrorKind::None {
            fail(3, f"f32 bits {bits:#x} -> '{show(b, n)}' -> {back:#x} kind {err.kind as u8}")
            break
        }

        if (i & 15) == 0 && !nan {
            var slow = parse_f32_exact(b, n, &err).to_bits()
            if slow != bits || err.kind != ParseErrorKind::None {
                fail(3, f"f32 bits {bits:#x} -> '{show(b, n)}' -> exact path {slow:#x} kind {err.kind as u8}")
                break
            }
        }
    }

    if longest != F32_TEXT_MAX {
        fail(4, f"longest f32 text {longest}, stated {F32_TEXT_MAX}")
    }

    if first_failure == 0 {
        println("ok")
    }

    return first_failure
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
// The 32-bit arithmetic path, forced on this host.
// RUN: %kairo %s -O2 -DKAIRO_NUMTEXT_NARROW -o %t.narrow.exe --cache-dir %t.dn
// RUN: %t.narrow.exe | %FileCheck %s
