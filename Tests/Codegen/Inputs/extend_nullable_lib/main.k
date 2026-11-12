// Calls the extension nlib.k gives i32? (Codegen/extend_builtin_matrix_nullable.k).
import nlib
fn main() -> i32 {
    var a: i32? = null
    var b: i32? = 5
    return a.or_one() + b.or_one() - 6
}
