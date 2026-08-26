/// --- The Kairo Project --- Tests/NumericConformance/bitwise_and_shifts.k --- ///
///
/// Masks, shifts, and the sign-extension question. The compiler's own sources
/// are full of these -- limb splitting in the BigInt path, file-id packing in
/// SourceLocation, flag words throughout -- and every one of them is wrong in a
/// way that produces a plausible number rather than a crash.
///
/// The specific hazard this file exists for: a mask whose constant is mistyped
/// becomes a no-op. `val & 0xFFFFFFFF` where the constant is -1 returns `val`
/// unchanged, so the code reads as "take the low 32 bits" and does nothing at
/// all. That shipped in stage 0 (see integer_32bit_band.k); roughly twenty
/// limb masks in Compiler/Lexer/Immediate.k were dead because of it.
///
/// DECISION: `>>` on a SIGNED value is asserted to be arithmetic (sign-filling)
/// and on an UNSIGNED value to be logical (zero-filling), which is what C, C++,
/// Rust and LLVM's `ashr`/`lshr` split gives. If Kairo instead defines `>>` as
/// always-logical, checks 9-11 will fail and the decision needs recording
/// rather than the file needs patching.
///
/// STAGE 0 TODAY: PASSES. Note this is not in tension with stage 0's mask bug:
/// the masks below are built from shifts rather than spelled as literals, which
/// is exactly the workaround Compiler/Support/Limits.k applies. Spelling them
/// as `0xFFFFFFFF` instead is what fails, and that is checked in
/// integer_32bit_band.k rather than duplicated here.
///

fn main() -> i32 {
    var one: u64 = 1;
    var wide: u64 = 0x1122334455667788;

    // ---- checks 1-3: masks must actually mask -------------------------------
    // A no-op mask returns the input. The expected values are written out in
    // full rather than derived, so that a broken mask cannot satisfy a broken
    // derivation of what it should produce.
    var low8:  u64 = (one << 8) - 1;
    var low16: u64 = (one << 16) - 1;
    var low32: u64 = (one << 32) - 1;
    if (wide & low8)  != 0x88       { return 1; }
    if (wide & low16) != 0x7788     { return 2; }
    if (wide & low32) != 0x55667788 { return 3; }

    // ---- check 4: the mask must not be the identity -------------------------
    // Stated separately and explicitly. This is the assertion stage 0's dead
    // masks would have failed, and it is worth having as its own check because
    // a reader scanning results sees "the mask did nothing" rather than having
    // to compare two long hex numbers.
    if ((wide & low32) == wide) != false { return 4; }

    // ---- checks 5-8: the other bitwise operators ----------------------------
    var a: u64 = 0b1100;
    var b: u64 = 0b1010;
    if (a & b) != 0b1000 { return 5; }
    if (a | b) != 0b1110 { return 6; }
    if (a ^ b) != 0b0110 { return 7; }
    // Complement of 0 is all ones. This is how USIZE_MAX is spelled in
    // Compiler/Support/Limits.k, so a failure here invalidates that constant.
    var zero: u64 = 0;
    if (~zero) != 0xFFFFFFFFFFFFFFFF { return 8; }

    // ---- checks 9-11: right shift and sign ----------------------------------
    // Unsigned: zero-filling. The top bit must NOT propagate.
    var top_set: u64 = one << 63;
    if (top_set >> 63) != 1 { return 9; }

    // Signed and negative: sign-filling. -8 >> 1 is -4, and -1 >> anything
    // stays -1. If these come back as huge positive numbers, `>>` is logical
    // on signed values -- see the DECISION note in the header.
    var neg8: i64 = -8;
    var neg1: i64 = -1;
    if (neg8 >> 1) != -4  { return 10; }
    if (neg1 >> 40) != -1 { return 11; }

    // ---- checks 12-13: left shift ------------------------------------------
    // The shift used throughout this directory to build reference values. If
    // this is wrong, every other file's expected values are wrong with it, so
    // it is checked against literals that are small enough to be beyond doubt.
    if (one << 0) != 1     { return 12; }
    if (one << 10) != 1024 { return 13; }

    // ---- check 14: shift-then-mask round trip -------------------------------
    // Split a 64-bit value into two 32-bit limbs and reassemble it. This is the
    // exact operation the BigInt multiply performs, and the exact one that was
    // silently broken. If the low mask is a no-op, the reassembled value has
    // the low half of the original in BOTH halves and this fails.
    var hi: u64 = wide >> 32;
    var lo: u64 = wide & low32;
    if ((hi << 32) | lo) != wide { return 14; }

    return 0;
}
