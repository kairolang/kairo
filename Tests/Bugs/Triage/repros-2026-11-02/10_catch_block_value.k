// Language gap (design call): a catch arm cannot be a block that runs
// statements and yields a value.
// Expected (if supported): exit 11 (code 1 recorded + 10).
// Actual: S054E "expected '}' to close set literal" -- `{` after `=>` parses as
// a set literal. Today this needs a helper function.
struct Bad { var code: i32 }
fn risky() panic(Bad) -> i64 { panic Bad { code: 1 } }

fn main() -> i32 {
    var code = 0
    var r = try risky() catch e: Bad => { code = e.code; 10 }
    return (r as i32) + code
}
