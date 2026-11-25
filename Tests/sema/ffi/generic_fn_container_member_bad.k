// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC
//
// A member call on a dependent imported container instance inside a generic
// function: a name the pattern does not have is rejected at the definition
// (an argument no instance member accepts is the instance's error:
// generic_fn_container_member_inst.k).

ffi "c++" import "vector"

fn <T> missing(v: cxx::std::vector<T>) -> usize {
    // TC: generic_fn_container_member_bad.k:[[@LINE+1]]:14: error [R025E]: no member named 'no_such_member' in 'std::vector'
    return v.no_such_member()
}

fn main() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(1)
    return missing(v) as i32
}
