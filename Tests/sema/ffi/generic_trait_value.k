// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 110
//
// `ns::Trait<T>::value` with T a Kairo generic parameter. The member
// comes from a base over a builtin of the arguments (libc++ derives every
// trait from integral_constant<bool, __is_xxx(T)>), which the pattern does
// not show, so C++ looks it up per instantiation; it is not R025E "no member
// named 'value' in 'is_trivially_destructible'". As an `eval if` condition it
// is a compile-time value per instance, not SC001E "this is a run-time value".
// The concrete `<i32>` form resolves too (generic_scope_step.k).
// Codegen spells the member through the instance (`::std::is_trivially_
// destructible<T>::value`) and clang decides it per instantiation: the run
// checks both a trivial and a non-trivial T take their own branch.

ffi "c++" import "type_traits";
ffi "c++" import "memory";

class <T> Pool {
    fn clear(self, p: unsafe *T) {
        eval if !cxx::std::is_trivially_destructible<T>::value {
            cxx::std::destroy_at(p)
        }
    }
}

fn <T> trivial() -> bool {
    return cxx::std::is_trivially_destructible<T>::value
}

fn <T> branch() -> i32 {
    eval if cxx::std::is_trivially_destructible<T>::value { return 1 }
    return 0
}

class Res {
    var n: i32
    fn Res(self) { self.n = 1 }
    fn op finally(self) { self.n = 0 }
    @move fn Res(self, other: Self) = default
}

fn concrete() -> bool { return cxx::std::is_trivially_destructible<i32>::value }

fn main() -> i32 {
    var n = branch<i32>() * 10 + branch<Res>()
    if trivial<f64>() && (!trivial<Res>()) && concrete() { n += 100 }
    return n
}

// DIAG-NOT: error
