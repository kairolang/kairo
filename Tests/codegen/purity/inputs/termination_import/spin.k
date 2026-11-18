// Imported by termination_import.k: a function that never returns for odd
// `n`, inferred const in this module and left without the attribute.
pub fn spin(n: i32) -> i32 {
    var i = 0
    while i != n { i += 2 }
    return i
}
