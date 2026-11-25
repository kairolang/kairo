// i256 and u512 in public signatures, which C++ sees as _BitInt(256) and
// unsigned _BitInt(512) (kcc_include_bitint_wide.k).
pub fn widen(v: u512) -> u512 {
    return v << 3
}

pub fn less(v: i256) -> i256 {
    return v - 1
}
