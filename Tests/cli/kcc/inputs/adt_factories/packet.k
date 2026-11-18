// kcc_adt_factories.k's module: ADT enums C++ builds through their
// factories (`E::V(fields...)`) instead of the tag form.

// Generic: a payload of the parameter's type, a concrete one, and a unit
// variant. Frame<i32> is an instance this module names, so the header
// declares it `extern template`.
pub enum <T> Frame {
    Burst { base: T, count: i32 },
    Code  { status: i32 },
    Idle,
}

// Non-generic, with a field that is not moved as bytes (the lambda form).
pub enum Res {
    Ok   { v: i32 },
    Err  { msg: string, code: i32 },
    Nothing,
}

// Niche-filled: no tag, the unit variant is the pointer's null.
pub enum <T> Maybe { Some { v: T }, None }

pub fn sum_burst(f: Frame<i32>) -> i32 = match f {
    case .Burst(var base, var count) => base + count
    case .Code(var status)           => 1000 + status
    case .Idle                       => -1
}

pub fn sum_wide(f: Frame<i64>) -> i64 = match f {
    case .Burst(var base, var count) => base * count
    case .Code(var status)           => status as i64
    case .Idle                       => 0
}

pub fn res_code(r: Res) -> i32 = match r {
    case .Ok(var v)                  => v
    case .Err(var msg, var code)     => code + (msg.size() as i32)
    case .Nothing                    => -7
}

pub fn deref_or(m: Maybe<*i32>, d: i32) -> i32 = match m {
    case .Some(var v) => *v
    case .None        => d
}
