/// --- The Kairo Project --- Tests/NumericConformance/overflow_and_wraparound.k --- ///
///
/// What happens at the top of a type's range. This is where a compiler's
/// arithmetic stops being arithmetic and starts being a policy decision, and
/// where the policy has to be the same one at every width or none of it can be
/// reasoned about.
///
/// DECISION 1 -- WRAPPING. Unsigned arithmetic is asserted to WRAP modulo 2^N.
/// That is defined behaviour in C, C++, Rust and LLVM, and the compiler's own
/// BigInt carry detection depends on it: `new_lo += addend; if new_lo < addend`
/// in Compiler/Lexer/Immediate.k detects a carry by observing the wrap. If
/// unsigned arithmetic ever traps or saturates instead, that code silently
/// stops detecting carries, and this file is how you find out.
///
/// DECISION 2 -- PROMOTION. Whether `u8 + u8` is computed at 8 bits (Rust) or
/// promoted to a wider type first (C, C++) changes what "wrap" even means for
/// narrow types. Checks 1-6 sidestep the question by storing the result back
/// into the narrow type, which truncates under either rule and is therefore a
/// real assertion rather than a bet. Check 15 pins the promotion rule itself
/// and is the only check in this file that would need to change if Kairo picks
/// the other one -- see its comment.
///
/// SIGNED overflow is deliberately NOT exercised. In C and C++ it is undefined
/// behaviour, in Rust it panics in debug and wraps in release, and Kairo has
/// not stated a rule. A check either way would encode a decision nobody has
/// made. When Kairo decides, add the checks here and say which rule they
/// encode; until then the absence is the honest state.
///
/// STAGE 0 TODAY: PASSES.
///

fn main() -> i32 {
    // ---- checks 1-2: u8 wrap ------------------------------------------------
    // 255 + 1 == 0, and 0 - 1 == 255, observed at the storage width. Checked at
    // the narrowest width first: a compiler that computes wide and forgets to
    // truncate on store passes every wider check and fails here.
    var u8_max:  u8 = 255;
    var u8_zero: u8 = 0;
    var u8_one:  u8 = 1;
    var u8_up:   u8 = u8_max + u8_one;
    var u8_down: u8 = u8_zero - u8_one;
    if u8_up != 0     { return 1; }
    if u8_down != 255 { return 2; }

    // ---- checks 3-4: u16 wrap -----------------------------------------------
    var u16_max:  u16 = 65535;
    var u16_zero: u16 = 0;
    var u16_one:  u16 = 1;
    var u16_up:   u16 = u16_max + u16_one;
    var u16_down: u16 = u16_zero - u16_one;
    if u16_up != 0       { return 3; }
    if u16_down != 65535 { return 4; }

    // ---- checks 5-6: u32 wrap -----------------------------------------------
    // The maximum is built by shifting rather than spelled, because spelling it
    // is the stage-0 bug; see integer_32bit_band.k. A failure here with the
    // maximum built this way is a genuine wraparound failure, not a literal
    // failure, and preserving that distinction is why it is built and not
    // written.
    var u32_max:  u32 = static_cast::<u32>((static_cast::<u64>(1) << 32) - 1);
    var u32_zero: u32 = 0;
    var u32_one:  u32 = 1;
    var u32_up:   u32 = u32_max + u32_one;
    var u32_down: u32 = u32_zero - u32_one;
    if u32_up != 0         { return 5; }
    if u32_down != u32_max { return 6; }

    // ---- checks 7-8: u64 wrap -----------------------------------------------
    // At 64 bits there is no wider type to promote to, so this is the width
    // where wrapping is unambiguous and the rule is at its clearest.
    var u64_max:  u64 = 0xFFFFFFFFFFFFFFFF;
    var u64_zero: u64 = 0;
    var u64_one:  u64 = 1;
    if (u64_max + u64_one) != 0        { return 7; }
    if (u64_zero - u64_one) != u64_max { return 8; }

    // ---- checks 9-12: carry detection, what actually depends on this --------
    // The idiom from Compiler/Lexer/Immediate.k: after `sum = a + b`, a carry
    // occurred exactly when `sum < a`. This is the reason unsigned wrap has to
    // be defined rather than merely conventional.
    //
    // If check 9 fails while 7-8 pass, the wrap is happening but the comparison
    // after it is being folded against the un-wrapped value -- an optimiser
    // assuming the addition cannot overflow. That is far subtler than a wrong
    // sum, and knowing this check separates the two is the point of having it.
    var big: u64 = 0xFFFFFFFFFFFFFF00;
    var add: u64 = 0x200;
    var sum: u64 = big + add;
    if (sum < big) != true { return 9; }
    if sum != 0x100        { return 10; }

    // The negative case: no carry, no wrap, and the comparison must say so.
    // Without this, a compiler where `sum < a` is always true would pass 9.
    var small_a:   u64 = 100;
    var small_b:   u64 = 200;
    var small_sum: u64 = small_a + small_b;
    if (small_sum < small_a) != false { return 11; }
    if small_sum != 300               { return 12; }

    // ---- checks 13-14: multiplication wraps too -----------------------------
    // Addition and multiplication must agree about the rule. A compiler that
    // wraps on add but saturates on multiply is worse than one that saturates
    // on both, because the inconsistency stays invisible until the two are
    // mixed in one expression.
    var two63: u64 = static_cast::<u64>(1) << 63;
    var two32: u64 = static_cast::<u64>(1) << 32;
    if (two63 * 2) != 0     { return 13; }
    if (two32 * two32) != 0 { return 14; }

    // ---- check 15: the promotion rule itself --------------------------------
    // THIS IS THE ONE CHECK IN THIS FILE THAT ENCODES A LANGUAGE DECISION.
    //
    // `u8_max + u8_one` as an EXPRESSION, never stored into a u8. Under C-style
    // promotion both operands widen first and the result is 256. Under
    // Rust-style same-width arithmetic it is 0, identical to check 1.
    //
    // 256 is asserted because Kairo lowers through a C++ backend and inherits
    // C's integer promotions. If this returns 0 instead, Kairo has moved to
    // same-width arithmetic: that is a legitimate design, but it is a CHANGE,
    // and the correct response is to record the new rule somewhere citable and
    // then update this check -- not to treat it as a bug. Everything else in
    // this file holds under either rule.
    if (u8_max + u8_one) != 256 { return 15; }

    return 0;
}
