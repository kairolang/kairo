// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
//
// O25: an unscoped enumerator named through its class (`K::b1`) is spelled
// under its own enum, never another enum nested in the same class. Guards
// the value-overlap case; the name is read from the table of the file the
// enumerator's range lies in (CXXSpell::leaf).

ffi "c++" import "enum_two_unscoped_in_class.h"

fn main() -> i32 {
    var x = K();
    x.setB(K::b1);
    x.setA(K::a3);
    if x.getB() == K::b0 { return 1; }
    if x.getB() == K::b1 && x.getA() == K::a3 { return 0; }
    return 2;
}
