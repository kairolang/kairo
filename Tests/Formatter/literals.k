// RUN: %kfmt --stdout %s | diff -u %S/Expected/literals.k -
// RUN: %kfmt --check %S/Expected/literals.k
//
// Rule 1.6: literal text is copied byte for byte: f-strings, raw strings,
// chained strings, non-ASCII text, number spellings.

fn f(n: i32) -> string {
    var a = f"value {n} é ⣿";
    var b = r"raw \n text";
    var c = "chained "
        "pieces";
    var d = 0xFF + 0b1010;
    return a;
}
