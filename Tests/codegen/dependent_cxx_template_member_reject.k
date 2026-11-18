// Members of a C++ class template instance over a Kairo parameter, other
// than the ones in the covered shape: `back()`, `empty()` and a ranged-style
// index through a local, are decided per instance and compile and run
// without an internal error.

ffi "c++" import "vector";

class <T> Box {
    pub var v: cxx::std::vector<T>;
    fn add(self, x: T) { self.v.push_back(x); }
    fn last(self) -> T { return self.v.back(); }
    fn none(self) -> bool { return self.v.empty(); }
    fn first(self) -> T {
        var i: usize = 0;
        return self.v[i];
    }
}

fn main() -> i32 {
    var b: Box<i32>;
    if !b.none() { return 1; }
    b.add(6); b.add(8);
    if b.none() { return 2; }
    if b.last() != 8 { return 3; }
    if b.first() != 6 { return 4; }
    return 0;
}

// --- lit wiring ---
// RUN: rm -f %t.exe && rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='I003E' --implicit-check-not='internal' --implicit-check-not='error ['
// RUN: %t.exe
