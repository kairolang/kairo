// Calls into imported C++ overload sets go out by the set's name, so clang
// picks the overload; Sema records the same one, and the pass is silent.
//   - `push_back` with an `if` expression of two lvalues: the C++
//     conditional is an lvalue, and both take `const T&`.
//   - `std::pair<A, B>` from two lvalues: both take the forwarding
//     constructor template, which binds each as `T&`.
//
// Whether the pass reports unasked depends on how the compiler was built,
// so every RUN line says: -fsema-agreement reports, -fno-sema-agreement
// does not look, and --test-sema-agreement-quiet is a release-built
// compiler's unasked default, which counts and stays silent.

ffi "c++" import "vector"
ffi "c++" import "utility"

fn sum(const v: cxx::std::vector<i32>) -> i32 {
    var s: i32 = 0
    for x in v {
        s += x
    }
    return s
}

fn pick(c: bool, a: i32, b: i32) -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(if (c) => (a) else => b)
    var id: u32 = 3
    var p = cxx::std::pair<u32, i32>(id, a)
    return sum(v) + p.second
}

fn main() -> i32 {
    return pick(true, 1, 2)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=WARN --allow-empty
// WARN-NOT: I012W
// WARN-NOT: error
// RUN: %t.exe; test $? -eq 2

// Off: nothing is looked at.
// RUN: rm -rf %t.d
// RUN: %kairo %s -v -fno-sema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF-NOT: I012W
// OFF-NOT: sema agreement:
// OFF: compilation:

// A release-built compiler's default: nothing to count, nothing said.
// RUN: rm -rf %t.d
// RUN: %kairo %s -v --test-sema-agreement-quiet -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=QUIET
// QUIET-NOT: I012W
// QUIET-NOT: {{[1-9][0-9]*}} disagreed in {{.*}}imported_overload_sets.k
// QUIET: compilation:
// RUN: %t.exe; test $? -eq 2
