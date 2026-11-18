// Escaped (`#`) and non-ASCII names in other declaration positions (a type,
// a field, a method, a loop variable) mangle the same way at the
// declaration and every use. Exit 0 means every name resolved.
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe 2>&1 | %FileCheck %s --allow-empty --implicit-check-not='I003E' --implicit-check-not='error ['
// RUN: %t.exe

class Größe {
    pub var #w: i32 = 0
    pub var h#: i32 = 0
    pub fn flächen(self) -> i32 { return self.#w * self.h# }
}

fn #sum(n: i32) -> i32 {
    var t = 0
    for var i#x = 0; i#x < n; i#x += 1 { t += i#x }
    return t
}

fn main() -> i32 {
    var g = Größe()
    g.#w = 3
    g.h# = 4
    if g.flächen() != 12 { return 1 }
    if #sum(4) != 6 { return 2 }
    return 0
}
