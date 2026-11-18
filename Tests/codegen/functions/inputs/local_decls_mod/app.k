import lib::*

pub fn compute_here(x: i32) -> i32 {
    fn helper(v: i32) -> i32 { return v - 1 }   // lib's helpers' names, another file
    return helper(x)
}

fn main() -> i32 {
    // 3*3 + 1 = 10;  1000 + 5;  2;  4
    return compute(3) + (quick(5) - 1000) + tagged<i32>(1) + compute_here(5)   // 10 + 5 + 2 + 4
}
