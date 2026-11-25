// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=INST
// RUN: not test -e %t.exe
//
// A member call on a dependent imported container instance is decided per
// instance, as C++ decides it: the definition type-checks, and an argument
// no member of the instance accepts is an error when that instance is
// compiled, naming the instantiation that needs it.
// TC-NOT: error [

ffi "c++" import "vector"

fn <T> wrong(v: cxx::std::vector<T>) -> T {
    // INST: generic_fn_container_member_inst.k:[[@LINE+1]]:14: error [CL001E]: no matching member function for call to 'at'
    return v.at("x")
}

// INST: note [I900N]: in instantiation of function template specialization '{{.*}}wrong<int>' requested here

fn main() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(1)
    return wrong(v)
}
