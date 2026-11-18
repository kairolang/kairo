// @no_inline on a function that can panic.
// Expected: compiles, exit 7.
// Actual: CL001E "'nodiscard' attribute cannot be applied to types" -- the
// declaration is spelled `__attribute__((noinline)) [[nodiscard]] <Panic
// result> f(...)`; a standard attribute after a GNU one appertains to the
// type. Emit [[nodiscard]] first (or spell noinline as [[gnu::noinline]]).
struct Bad { var code: i32 }

@no_inline fn parse(x: i64) panic(Bad) -> i64 {
    if x < 0 { panic Bad { code: 1 } }
    return x
}

fn main() -> i32 {
    return (try parse(7) catch => 0) as i32   // exit 7
}
