// `{x}` on an integer or a float with no spec, linked -O2 for
// x86_64-linux-musl and pinned by the calls each lowering makes. Each k_*
// is one f-string behind @no_inline so its code can be read on its own;
// main checks the text, including holes that land where the buffer has
// little room left and text that spills to the heap.

@no_inline fn k_i64(v: i64) -> string { return f"{v}" }
@no_inline fn k_u64(v: u64) -> string { return f"{v}" }
@no_inline fn k_f64(v: f64) -> string { return f"{v}" }

fn ck(const got: string, const want: string, code: i32) -> i32 {
    if (got != want) || (got.capacity() < got.size()) { return code }
    return 0
}

fn main() -> i32 {
    var r = 0
    r = r + ck(k_i64(0), "0", 1)
    r = r + ck(k_i64(-7), "-7", 2)
    r = r + ck(k_i64(9999999999999999), "9999999999999999", 3)
    r = r + ck(k_i64(10000000000000000), "10000000000000000", 4)
    r = r + ck(k_i64(-9223372036854775807 - 1), "-9223372036854775808", 5)
    r = r + ck(k_u64(18446744073709551615), "18446744073709551615", 6)
    r = r + ck(k_u64(12345678901234567890), "12345678901234567890", 7)
    r = r + ck(k_f64(0.1), "0.1", 8)
    r = r + ck(k_f64(-2.5), "-2.5", 9)
    r = r + ck(k_f64(123456.789), "123456.789", 10)
    r = r + ck(k_f64(0.1 + 0.2), "0.30000000000000004", 11)
    r = r + ck(k_f64(1234567890123456.8), "1234567890123456.8", 12)
    r = r + ck(k_f64(1e21), "1e+21", 13)
    r = r + ck(k_f64(0.00012), "0.00012", 14)
    var d = 98765.4321
    var n: i64 = -42
    // 100 literal bytes first: the f-string stays inline and its holes
    // find 27 bytes of room.
    var t100 = "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
    var near = f"0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789{d}|{n}"
    r = r + ck(near, t100.copy() + "98765.4321|-42", 15)
    // 130 bytes of text first: the buffer spills before the holes.
    var t130 = t100.copy() + "012345678901234567890123456789"
    var spill = f"{t130}{d}|{n}"
    r = r + ck(spill, t130.copy() + "98765.4321|-42", 16)
    // A narrow integer's bound (11 bytes for an i32) is all the room the
    // buffer keeps for it: the hole must not grow the buffer, inline (110
    // literal bytes) or on a heap block sized to the bound (140 bytes).
    var k: i32 = -1234567890
    var inl = f"01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789{k}"
    r = r + ck(inl, t100.copy() + "0123456789-1234567890", 17)
    if inl.capacity() >= inl.size() + 16 { r = r + 18 }
    var heap = f"01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789{k}"
    r = r + ck(heap, t100.copy() + "0123456789" + "012345678901234567890123456789-1234567890", 19)
    if heap.capacity() >= heap.size() + 16 { r = r + 20 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// Pins, x86_64-linux-musl -O2:
//   k_i64 / k_u64  the digits come from one runtime call; the FmtBuf, the
//                  sign test, the spec dispatch and the finish are inline,
//                  and nothing goes through int64_'s digit scratch or
//                  number_'s copy.
//   k_f64          the sign is read in a register (no bits64_ call) and the
//                  FmtBuf constructor is inline.
// REQUIRES: clang, llvm-objdump, sysroot-x86_64-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-musl -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %objdump -d --no-show-raw-insn %t.exe > %t.asm
// RUN: %FileCheck %s --check-prefix=PIN < %t.asm
// PIN-LABEL: 5k_i64{{.*}}>:
// PIN-NOT: {{int64_|bits64_|FmtBufC|number_}}
// PIN: callq {{.*}}<kairo_rt_fmt_dec_u64>
// PIN-NOT: {{int64_|bits64_|FmtBufC|number_}}
// PIN-LABEL: 5k_u64{{.*}}>:
// PIN-NOT: {{int64_|bits64_|FmtBufC|number_}}
// PIN: callq {{.*}}<kairo_rt_fmt_dec_u64>
// PIN-NOT: {{int64_|bits64_|FmtBufC|number_}}
// PIN-LABEL: 5k_f64{{.*}}>:
// PIN-NOT: {{bits64_|FmtBufC}}
// PIN: callq {{.*}}<kairo_rt_fmt_f64>
// PIN-NOT: {{bits64_|FmtBufC}}
// PIN-LABEL: >:
