// A member call inside the index of a subscript whose base is a field of a
// duck parameter (`self.dyn()->xs[self.dyn()->xs.size() - 1]`) is typed,
// although the base is unknown, so EmitIR sees no "unbound callee".

ffi "c++" import "vector";

class <T: type> Mix {
    inline fn dyn(self) -> unsafe *T { return unsafe (&self as *T); }
    fn last(self) -> unsafe *i32 {
        if self.dyn()->xs.empty() { return &null; }
        return unsafe &self.dyn()->xs[self.dyn()->xs.size() - 1];
    }
}

class Host derives Mix<Host> {
    var xs: cxx::std::vector<i32>;
    
}

fn main() -> i32 {
    var h: Host;
    if h.last() != &null { return 9; }
    h.xs.push_back(5); h.xs.push_back(7);
    return *h.last();
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: I003E
// DIAG-NOT: unbound callee
// RUN: %t.exe; test $? -eq 7
