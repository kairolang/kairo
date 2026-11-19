// A by-value parameter of a copyable record whose copy is not free (it has
// a destructor) is passed by const reference when the body never mutates
// it; one the body writes is passed by value. The caller's value is not
// moved either way.

class Txt {
    pub var n: usize = 0
    fn Txt(self, n: usize) { self.n = n }
    @copy fn Txt(self, const other: Self) { self.n = other.n }
    fn op finally(self) { }
}

// The counter keeps both from being inferred `const`, which is never passed
// by reference.
var calls: usize = 0

fn read(t: Txt) -> usize { calls += 1; return t.n }
fn bump(t: Txt) -> usize { calls += 1; t.n += 1; return t.n }

fn main() -> i32 {
    var t = Txt(4)
    return (read(t) + bump(t) + t.n + calls) as i32   // 4 + 5 + 4 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-DAG: read(const::param_const_ref_copy_record::Txt & t) noexcept;
// CXX-DAG: bump( ::param_const_ref_copy_record::Txt t) noexcept;
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
