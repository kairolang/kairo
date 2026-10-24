// build: kairo F1-dotted-variant-as-left-operand-of-eq.k   (expect exit 0)
enum Dir { North, South }

fn main() -> i32 {
    var d: Dir = .South
    if d == .South { }      // accepted
    if .South == d {        // SC123E: the dotted LEFT operand gets no expected type
        return 0
    }
    return 1
}
