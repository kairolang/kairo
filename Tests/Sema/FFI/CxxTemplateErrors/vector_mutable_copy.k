ffi "c++" import "vector"

pub class Box {
    pub var v: i32
    pub fn Box(self) = default

    @copy
    pub fn Box(self, other: Self) {
        self.v = other.v
    }

    pub fn Box(self, v: i32) {
        self.v = v
    }
}

fn main() -> i32 {
    var b   = Box(10)
    var vec = cxx::std::vector<Box>()
    vec.push_back(b)
    vec.push_back(Box(10))
    return (vec.size() as i32) - 2
}

// --- lit wiring ---
// Both pushes copy a Box inside libc++ (push_back takes a `const Box&`, and
// growing the vector needs a move): one Kairo error at each call, none in
// the C++ headers, and the `const` fix applies, compiles and runs.
// RUN: rm -rf %t && mkdir -p %t
// RUN: cp %s %t/box.k
// RUN: { %kairo %t/box.k -o %t/box.exe --cache-dir %t/c1 2>&1 || true; } > %t/diag.txt
// RUN: %FileCheck %s --input-file=%t/diag.txt --implicit-check-not="error [" --implicit-check-not="in instantiation of"
// RUN: { %kairo %t/box.k -o %t/box.exe --cache-dir %t/c1 --diag-cxx-chain 2>&1 || true; } | %FileCheck %s --check-prefix=CHAIN
// RUN: python3 %S/../../../../Scripts/apply_fixits.py --from %t/diag.txt 2>&1 | %FileCheck %s --check-prefix=APPLIED
// RUN: %kairo %t/box.k -o %t/fixed.exe --cache-dir %t/c2
// RUN: %t/fixed.exe
//
// CHECK: box.k:20:9: error [SC302E]: 'Box' cannot be copied here: instantiating member function 'std::vector<{{.*}}Box>::push_back' copies it from a const object or a temporary, and its copy constructor takes a non-const 'other' (C++ 'Box(Box&)') and it has no move constructor
// CHECK-NEXT: fix-it:"{{.*}}box.k":{8:22-8:22}:"const "
// CHECK-NEXT: box.k:8:22: note [I900N]: the copy constructor of 'Box' is declared here; with 'const other' it copies from const objects and temporaries too
// CHECK-NEXT: allocator_traits.h:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: C++ reports: no matching function for call to '__construct_at'
// CHECK-NEXT: note [I900N]: {{[0-9]+}} C++ instantiation steps lead from this use to the error; --diag-cxx-chain shows them
// CHECK-NEXT: note [I900N]: C++ reports a template that does not compile once, at its first use: a later use of the same template fails for the same reason
// CHECK: note [I900N]: C++ also reports: static assertion failed {{.*}}Cpp17MoveInsertable
//
// CHAIN: box.k:20:9: error [SC302E]: 'Box' cannot be copied here
// CHAIN: box.k:20:9: note [I900N]: in instantiation of member function 'std::vector<{{.*}}Box>::push_back' requested here
//
// APPLIED: changed 1 file(s)
