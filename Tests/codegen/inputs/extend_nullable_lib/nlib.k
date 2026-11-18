// An `extend i32?` in another file (codegen/extend_builtin_matrix_nullable.k).
pub extend i32? { pub fn or_one(self) -> i32 { if self? { return self } return 1 } }
