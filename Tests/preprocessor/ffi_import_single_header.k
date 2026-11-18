// A single-header ffi import is accepted in both forms, with and without
// `as name`, and the header's symbols are usable: the import-form checks that
// reject a brace list, two headers and a lone `ffi` do not reject a correct
// one-header line.

ffi "c++" import "vector"
ffi "c++" import "string" as str

fn main() -> i32 {
    var v: cxx::std::vector<i32>
    v.push_back(5)
    var s: cxx::std::string
    return v.size() as i32 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not="error ["
// CHECK-NOT: S064E
// RUN: rm -f %t.exe
// RUN: %kairo %s -O0 -o %t.exe
// RUN: %t.exe; test $? -eq 3
// RUN: %kairo %s -O2 -o %t.exe
// RUN: %t.exe; test $? -eq 3
