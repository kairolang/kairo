// RUN: %kfmt --stdout %s | diff -u %S/expected/byte_strings.k -
// RUN: %kfmt --check %S/expected/byte_strings.k
//
// A byte string is printed as written: the `b` stays glued to its quote,
// the escapes are not touched, and a chain of byte strings is one literal.

fn w(  xs: [const u8;] ) -> usize {
    var a   =   b"ab\x00\xff"
    var c = b"ab"   b"cd"
    w( b"one "
        b"two\n" )
    var b = 1
    return w(b"x") +   xs.len
}
