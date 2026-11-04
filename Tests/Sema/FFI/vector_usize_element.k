// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
//
// G87: an element of `cxx::std::vector<usize>` is usize. The instance is
// `vector<unsigned long>` to C++ and `unsigned long` canonicalizes to u64,
// so `v[i]`, `*it` and a ranged-for binding came back u64: SC028E into a
// usize, SC033E in `v[0] + n`, SC063E as an argument. Inside the fill the
// argument's own Kairo type is the answer (TypeImport::_int_args), as for
// a pointer argument.

ffi "c++" import "vector";

fn twice(i: usize) -> usize { return i + i; }

fn main() -> i32 {
    var v: cxx::std::vector<usize>;
    v.push_back(4);
    v.push_back(5);
    var a: usize = v[0];
    var n: usize = 1;
    var b: usize = v[1] + n;
    var c: usize = twice(v[0]);
    var sum: usize = 0;
    for var off: usize in v { sum += off; }
    // 4 + 6 + 8 + 9 = 27, less 18
    return ((a + b + c + sum) as i32) - 18;
}

// DIAG-NOT: error
