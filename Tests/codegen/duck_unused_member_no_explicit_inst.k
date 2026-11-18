// A `<T: type>` record is C++-checked per instance: a member
// body that uses an operator T lacks is an error only for an instance that
// CALLS it. The explicit instantiation `template class FL<NoEq>;` the plan
// writes for every instance instantiates EVERY member, so FL<NoEq> failed
// in clang ("invalid operands to binary expression") though nothing calls
// find on it. A duck record's instances are instantiated implicitly instead
// (bodies are visible in every TU), exactly the members that are used.

class NoEq { pub var x: i32 = 0 }

class <T: type> FL {
    pub var items: unsafe *T = &null
    pub var count: usize = 0
    fn first(self) -> unsafe *T { return self.items }
    fn find(self, val: T) -> usize {
        for var i: usize = 0; i < self.count; ++i {
            if self.items[i] == val { return i }
        }
        return 99
    }
}

fn main() -> i32 {
    var n: FL<NoEq>
    n.first()
    var k: FL<i32>
    // find is used on FL<i32>, which has op ==.
    var v: i32 = 3
    if k.find(v) != 99 { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -fduck-generics %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}duck_unused_member_no_explicit_inst.k
// CXX-NOT:   template class{{.*}}FL<

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
