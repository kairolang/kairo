// The imported module of Tests/Codegen/SemaAgreement/interface_pch.k. The
// generic body is held by the interface PCH, parsed there and by no TU.

pub fn chosen(x: i32) -> i32 { return x + 1 }
pub fn other(x: i32) -> i32 { return x + 100 }

pub fn <T> twice(x: T) -> i32 { return chosen(2) }

pub fn plain(x: i32) -> i32 { return x }
