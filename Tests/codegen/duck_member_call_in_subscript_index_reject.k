// Neighbouring shapes of a duck member call in a subscript index: the index
// call on the duck base, a second index offset, and a plain local index.
// None ends in an internal error, and the values read are right (exit 0).

ffi "c++" import "vector";

class <T: type> Mix {
    inline fn dyn(self) -> unsafe *T { return unsafe (&self as *T); }
    fn last(self) -> i32 {
        return unsafe self.dyn()->xs[self.dyn()->xs.size() - 1];
    }
    fn prev(self) -> i32 {
        return unsafe self.dyn()->xs[self.dyn()->xs.size() - 2];
    }
    fn at(self, i: usize) -> i32 {
        return unsafe self.dyn()->xs[i];
    }
}

class Host derives Mix<Host> {
    var xs: cxx::std::vector<i32>;
}

fn main() -> i32 {
    var h: Host;
    h.xs.push_back(5); h.xs.push_back(7); h.xs.push_back(11);
    if h.last() != 11 { return 1; }
    if h.prev() != 7 { return 2; }
    if h.at(0) != 5 { return 3; }
    return 0;
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t2.exe
// RUN: rm -rf %t.d
// RUN: { %kairo -fduck-generics %s -O0 -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: I003E
// DIAG-NOT: unbound callee
// DIAG-NOT: error
// RUN: %t.exe
// RUN: { %kairo -fduck-generics %s -O2 -o %t2.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %t2.exe
