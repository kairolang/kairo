// A primitive limit at the head of a longer chain. Only the first
// step is the limit; the steps after it apply to the minted literal, as they
// do to `(f64::NAN).is_nan()`. Integer limits too, the negative ones
// parenthesized so `i32::MIN.neg_()` is the call on -2147483648.

extend i32 {
    fn sq(const self) -> i64 {
        return (self as i64) * (self as i64)
    }

    fn neg_(const self) -> bool {
        return self < 0
    }
}

extend u8 {
    fn twice(const self) -> u32 {
        return (self as u32) * 2
    }
}

fn ok() -> bool {
    var a = f64::NAN.is_nan()
    var b = f64::MAX.is_finite()
    var c = f32::INFINITY.is_infinite()
    var d = f64::MAX.abs().is_normal()
    var e = i32::MAX.sq()
    var f = i32::MIN.neg_()
    var g = u8::BITS.twice()
    var h = f16::MIN_SUBNORMAL.to_bits()
    var i = bf16::EPSILON.sqrt()
    // The software floats' limits are class statics, not literals.
    var j = f256::NAN.is_nan()
    var k = f512::MIN.is_sign_negative()
    var l = f256::EPSILON.sqrt().is_normal()
    return a && b && c && d && e > 0 && f && g == 16 && h == 1 && i > 0.0 && j && k && l
}

// Not limits: still ChainBinding's "no member". A limit the type lacks at
// the head of a chain is primitive_limit_chain_errors.k.
fn bad() {
    var x = f64::MAX::nope
    var y = i32::NOPE.sq()
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// The good chains type-check; the bad ones are the errors they were.
// CHECK-NOT: primitive_limit_chain.k:{{2[3-9]|3[0-7]}}:{{.*}}error
// CHECK: primitive_limit_chain.k:42:13: error [R024E]: 'f64' is a primitive type; it has no member 'MAX'
// CHECK: primitive_limit_chain.k:43:13: error [R024E]: 'i32' is a primitive type; it has no member 'NOPE'
// CHECK-NOT: error [
