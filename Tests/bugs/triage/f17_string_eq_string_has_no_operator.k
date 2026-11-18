// build: kairo f17_string_eq_string_has_no_operator.k -o f28   (expect exit 0)
fn main() -> i32 {
    var n = 1
    var s = f"quit{n}"
    if s == "quit1" {           // SC066E: Lib/builtin/string.k declares no `op ==`
        return 0
    }
    return 1
}
