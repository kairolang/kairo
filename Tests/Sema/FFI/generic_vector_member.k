// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// A member of a C++ class template instance over a Kairo parameter
// (`self.v[i]`, `self.v.size()` on a `cxx::std::vector<T>`). The pattern's
// signatures are dependent -- `operator[](size_type)`, size_type being
// `allocator_traits<A>::size_type` -- and imported as an opaque type no
// argument converts to: SC063E "cannot convert argument of type 'usize' to
// parameter '__n' of type '<ffi type>'", and SC066E on `i < v.size()`. C++
// resolves a call on a dependent object per instantiation; so does Kairo now.
// The concrete instance still resolves at the definition (f), and a
// concrete instance's call inside main still binds its member. Type-check
// only: emitting a call left to the instance (`self.v.push_back(x)`) is
// codegen's follow-up.

ffi "c++" import "vector";

fn bad(v: cxx::std::vector<i32>) {
    // DIAG-NOT: error [
    // DIAG: generic_vector_member.k:[[@LINE+1]]:5: error [SC063E]: no matching overload for call to 'push_back'
    v.push_back(true)
}

fn f(v: cxx::std::vector<i32>, i: usize) -> i32 { var r = v[i]; return r }

class <T> Box {
    pub var v: cxx::std::vector<T>
    fn push(self, x: T) { self.v.push_back(x) }
    fn at(self, i: usize) -> T { return self.v[i] }
    fn last(self) -> T { return self.v[self.v.size() - 1] }
    fn has(self, i: usize) -> bool { return i < self.v.size() }
    fn first(self) -> T { return self.v[0] }
}

fn main() -> i32 {
    var b = Box<i32>()
    b.push(10)
    b.push(30)
    var n = 0
    if b.has(1) && (!b.has(2)) { n = 2 }
    return b.at(0) + b.last() + n + (b.first() - 10)
}

// DIAG-NOT: error [

