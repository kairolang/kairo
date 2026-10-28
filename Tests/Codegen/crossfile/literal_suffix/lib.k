// Suffixed literals in bodies another file compiles: a generic function's
// template body and an inline one are emitted into the importer's TU, whose
// own immediate table does not hold these literals -- the spelling reads
// this file's (EmitIR::_owning_fid).

pub fn <T> scaled(x: T) -> f32 { return 1_000.5f32 + 0.5f32 }

pub inline fn mask() -> u64 { return 0xFFFF_FFFF_FFFF_FFFFu64 }

pub inline fn floor8() -> i8 { return -128i8 }

pub fn <T> wide(x: T) -> u128 { return 18446744073709551616u128 + 1u128 }
