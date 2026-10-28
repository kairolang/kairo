// An eval fn, an eval method and eval fields of every lowering, reached
// from another file: a consteval body is part of the interface, and so is
// the definition of a thunked eval field (it follows the thunk's body).
pub eval fn cube(x: i32) -> i32 { return x * x * x }

pub class Tbl {
    pub eval SIZE: i32 = 4
    pub eval BIG: i64 = cube(5)
    pub eval fn scaled(n: i32) -> i32 { return n * Tbl::SIZE }
}

// Hoisted out of a file-scope `eval if`: the importer sees the taken one.
pub eval FLAVOR = 2
eval if FLAVOR == 2 {
    pub fn hoisted() -> i32 { return 5 }
} else {
    pub fn hoisted() -> i32 { return not_on_this_target() }
}
