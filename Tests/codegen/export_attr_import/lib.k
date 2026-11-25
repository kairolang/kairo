// Imported by main.k: an export `main` never calls, and an `inline` one,
// whose body is written into every TU that imports it.

@export("lib_unused")
pub fn unused(n: i32) -> i32 {
    return n + 100
}

@export("lib_inl")
pub inline fn inl(n: i32) -> i32 {
    return n + 7
}
