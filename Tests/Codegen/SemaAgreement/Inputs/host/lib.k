// The Kairo file Tests/Codegen/SemaAgreement/host_include.k's C++ host
// includes. The host compiles the generic's body itself.

pub fn chosen(x: i32) -> i32 { return x + 1 }
pub fn other(x: i32) -> i32 { return x + 100 }

pub fn <T> twice(x: T) -> i32 { return chosen(2) }
