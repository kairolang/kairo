// Indexing a `const` slice parameter.
// Expected: compiles, exit 9.
// Actual: CL001E "no matching member function for call to 'operator[]'" --
// the slice type has no const operator[]. A non-const parameter works, and
// `for x in xs` over the const one works.
fn largest(const xs: [i64;]) -> i64 {
    var m = xs[0]
    for var i: usize = 1; i < xs.len; i += 1 { if xs[i] > m { m = xs[i] } }
    return m
}

fn main() -> i32 {
    var d: [i64;] = [5, -2, 9, 3]
    return largest(d) as i32   // exit 9
}
