// An eval fn, an eval method and eval fields of every lowering, reached
// from another file: a consteval body is part of the interface, and so is
// the definition of a thunked eval field (it follows the thunk's body).
pub eval fn cube(x: i32) -> i32 { return x * x * x }

pub class Tbl {
    pub eval SIZE: i32 = 4
    pub eval BIG: i64 = cube(5)
    pub eval fn scaled(n: i32) -> i32 { return n * Tbl::SIZE }
}
