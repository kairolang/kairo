// Disagreements the pass finds in ordinary code, with no test hook: calls
// into imported C++ overload sets, which go out by the set's name. Clang
// picks the overload, and Sema's recorded pick is another one.
//   - `push_back` with an `if` expression: Sema records the `T&&`
//     overload; the C++ conditional of two lvalues is an lvalue, and clang
//     takes `const T&`.
//   - `std::pair<A, B>` from two lvalues: Sema records
//     `pair(const A&, const B&)`; clang takes the forwarding template.
// Neither is repaired (the callees are members of a class template
// instance), and the program runs as clang resolved it.
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
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=WARN
// WARN-DAG: imported_overload_sets.k:30:5: warning [I012W]: internal: clang resolved this call to 'std::vector<int>::push_back(const_reference)', but Kairo's Sema chose 'push_back'; this is a compiler bug
// WARN-DAG: imported_overload_sets.k:32:13: warning [I012W]: internal: clang resolved this call to 'std::pair<unsigned int, int>::pair<unsigned int &, int &, 0>(unsigned int &, int &)', but Kairo's Sema chose 'pair'
// WARN-NOT: error
// RUN: %t.exe; test $? -eq 2

// Reported, the object is not cached: the next build says it again.
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=AGAIN
// AGAIN: warning [I012W]

// Off: nothing is looked at.
// RUN: rm -rf %t.d
// RUN: %kairo %s -v -fno-sema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF-NOT: I012W
// OFF-NOT: sema agreement:
// OFF: compilation:

// A release-built compiler's default: the two are counted and not said.
// RUN: rm -rf %t.d
// RUN: %kairo %s -v --test-sema-agreement-quiet -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=QUIET
// QUIET-NOT: I012W
// QUIET: sema agreement: {{.*}} 2 disagreed in {{.*}}imported_overload_sets.k
// QUIET-NOT: I012W
// RUN: %t.exe; test $? -eq 2

// Not said, the object is cached: the next build does not compile the file.
// RUN: %kairo %s -v --test-sema-agreement-quiet -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=CACHED
// CACHED-NOT: disagreed in {{.*}}imported_overload_sets.k
// CACHED: compilation:

// Asked for, it reports whatever the default is, and does not take the
// object a counting build stored.
// RUN: %kairo %s -fsema-agreement --test-sema-agreement-quiet -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=ASKED
// ASKED: warning [I012W]
