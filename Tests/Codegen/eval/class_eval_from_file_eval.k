// A class `eval` initialized from a file-level `eval` is a constant
// expression in C++: the binding it reads is defined before the field's
// definition evaluates the field's initializer.

eval HDR: usize = 2 * sizeof usize

class S {
    pub var n: usize = 0
    pub eval H: usize = HDR + 1

    pub fn S(self) { self.n = S::H }
}

fn main() -> i32 {
    var s = S()
    return (s.n + S::H) as i32 - 34
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
