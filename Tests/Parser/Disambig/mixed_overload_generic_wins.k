// Mixed overload set: one non-generic + one generic overload of the same
// name. The table stores BOTH (non-generic entries are negative evidence
// for rule 4), so the verdict must scan ALL entries insertion order can
// never hide the generic overload behind a non-generic first().

fn sum(a: i32) -> i32 {
    return a
}

fn <T> sum(v: T) -> T {
    return v
}

fn main() -> i32 {
    var s = sum<i32>(5)
    return 0
}
