// `for *x in s` over a C++ range whose `*it` is a `const T&`
// (std::set) binds `x` as `*const T`. It was `*T`, so the emitted
// `T* x = &*it` was clang's "cannot initialize 'int *' with 'const int *'"
// (CL001E). A container whose `*it` is mutable keeps a `*T` binder: the
// std::vector loop writes through it, and a const vector binds `*const T`.
ffi "c++" import "set"
ffi "c++" import "vector"

fn main() -> i32 {
    var s: cxx::std::set<i32>
    s.insert(3)
    s.insert(4)
    var t: i32 = 0
    for *x in s {
        t += *x
    }

    var v: cxx::std::vector<i32>
    v.push_back(10)
    for *y in v {
        *y = 20
    }

    // A const container: its `begin() const` yields `const T&` too.
    const cv = v
    var u: i32 = 0
    for *z in cv {
        u += *z
    }

    return t + v[0] + u
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 47
