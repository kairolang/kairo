// Driven by ../builtin_one_cxx_type.k: one set holding `usize` and `u64`.
fn f(n: i32) panic(usize, u64) -> i32 {
    if n == 1 { panic 7 as usize }
    if n == 2 { panic 9 as u64 }
    return n
}
fn main() -> i32 { return try f(3) catch => 0 }
