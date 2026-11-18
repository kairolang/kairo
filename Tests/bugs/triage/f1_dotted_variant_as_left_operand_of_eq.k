// build: kairo f1_dotted_variant_as_left_operand_of_eq.k   (expect exit 0)
enum Dir { North, South }

fn main() -> i32 {
    var d: Dir = .South
    if d == .South { }      // accepted
    if .South == d {        // SC123E: the dotted LEFT operand gets no expected type
        return 0
    }
    return 1
}
