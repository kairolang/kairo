// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
//
// A C++ container of a pointer to a NESTED Kairo record. Its stand-in was
// refused, so `vector<unsafe *T::Seg>` never filled: `begin` / `end` came
// from the pattern and tied (SC064E), `size()` had no type.

ffi "c++" import "vector"

class T {
    class Seg;
    var v: cxx::std::vector<unsafe *Seg> = cxx::std::vector<unsafe *Seg>()
    class Seg { pub var n: i32 = 0 }

    fn count(self) -> i32 {
        var c = 0
        for var p: unsafe *Seg in self.v { if p == &null { c += 1 } }
        return c + (self.v.size() as i32)
    }
}

fn main() -> i32 {
    var t: T
    t.v.push_back(&null)
    // one null element: 1 + size 1 = 2, plus 1
    return t.count() + 1
}

// DIAG-NOT: error
