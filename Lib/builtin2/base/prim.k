/// builtin/base/prim.k

import base::cmp::*
import base::hash::*
import base::intrinsics::*
import builtin::Null
import string::*

/// u8..u64, i8..i64, usize, isize, f32, f64, bool, char.
/// No Hash for floats (NaN != NaN, -0.0 == 0.0). No Default for bool.

priv macro prim_default!(T, zero) {
    extend T impl Default {
        static fn make_default() -> T = zero
    }
}

priv macro prim_hash!(T) {
    extend T impl Hash {
        fn hash(const self, @inout h: Hasher) {
            __builtin_trap() // BODY-TODO
}
}
}

priv macro prim_text!(T) {
extend T impl ToString {
fn op as (const self) -> string {
    __builtin_trap() // BODY-TODO
}
}

extend T impl Append {
fn append_to(const self, @inout out: string) {
    __builtin_trap() // BODY-TODO
}
}

extend T impl FromStr {
static fn from_str(const s: string, @inout err: ParseError) -> T? {
    __builtin_trap() // BODY-TODO
}
}
}

prim_default!(u8, 0)
prim_default!(u16, 0)
prim_default!(u32, 0)
prim_default!(u64, 0)
prim_default!(i8, 0)
prim_default!(i16, 0)
prim_default!(i32, 0)
prim_default!(i64, 0)
prim_default!(usize, 0)
prim_default!(isize, 0)
prim_default!(f32, 0.0)
prim_default!(f64, 0.0)

// Written out: a char literal passed as a macro argument does not reach the
// emitted C++ intact.
extend char impl Default {
    static fn make_default() -> char = '\x00'
}

prim_hash!(u8)
prim_hash!(u16)
prim_hash!(u32)
prim_hash!(u64)
prim_hash!(i8)
prim_hash!(i16)
prim_hash!(i32)
prim_hash!(i64)
prim_hash!(usize)
prim_hash!(isize)
prim_hash!(bool)
prim_hash!(char)

prim_text!(u8)
prim_text!(u16)
prim_text!(u32)
prim_text!(u64)
prim_text!(i8)
prim_text!(i16)
prim_text!(i32)
prim_text!(i64)
prim_text!(usize)
prim_text!(isize)
prim_text!(f32)
prim_text!(f64)
prim_text!(bool)
prim_text!(char)
