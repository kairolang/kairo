// O33: a `#` (or non-ASCII) name is one Kairo identifier but no C++ token;
// the declaration and every use must spell it the same mangled way, not ICE
// in EmitSink::spell. Exit 0 means all three names resolved and summed right.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe

fn f(#test: i32) -> i32 {
    var a#b = 1;
    var größe = 2;
    var #op = 3;
    var op# = 4;
    return #test + a#b + größe + #op - op#;
}

fn main() -> i32 {
    return f(1) - 3;
}
