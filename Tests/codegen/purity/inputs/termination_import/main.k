// The importer's declaration of `spin` and its own caller: neither carries a
// purity attribute, and the forward-declared functions take their
// definition's proof, not the empty one of their declaration.
import self::spin

fn late(n: i32) -> i32
fn w_late(n: i32) const -> i32

fn caller(n: i32) -> i32 { return spin::spin(n) + 1 }

fn main() -> i32 {
    return late(2) + w_late(2) + caller(2) - 7
}

fn late(n: i32) -> i32 {
    var i = 0
    while i != n { i += 2 }
    return i
}

fn w_late(n: i32) const -> i32 {
    var i = 0
    while i != n { i += 2 }
    return i
}
