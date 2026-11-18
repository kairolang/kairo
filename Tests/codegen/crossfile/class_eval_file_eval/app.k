// A class `eval` initialized from a file-level `eval` of its module is a
// constant expression in the importer's C++ as well: the binding is
// defined before the field's definition evaluates the field's thunk.
import lib::S

fn main() -> i32 {
    var s = S()
    return (s.n + S::H) as i32 - 34
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s %S/lib.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe
