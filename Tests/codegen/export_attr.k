// `@export(name)` defines the function a second time as the C function
// `name`, which forwards to it: the mangled symbol stays, and the C one is
// added beside it, whatever the function's visibility. An `ffi "c"` function
// exported under its own name is that symbol already. On wasm the C function
// is also exported from the module (the `wasm-export-name` attribute).

@export("ex_double")
pub fn twice(n: i32) -> i32 {
    return n * 2
}

@export("ex_sum")
fn sum(a: i64, b: i64) -> i64 {
    return a + b
}

@export("ex_self")
ffi "c" fn ex_self(n: i32) -> i32 {
    return n + 1
}

// The C name, reached the way a C caller reaches it.
ffi "c" fn ex_double(n: i32) -> i32
ffi "c" fn ex_sum(a: i64, b: i64) -> i64

fn main() -> i32 {
    return ex_double(10) + (ex_sum(20, 1) as i32) + ex_self(-21)
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.ir
// RUN: %kairo %s --emit=llvm-ir --cache-dir %t.ir
// RUN: %FileCheck %s --check-prefix=SYM < %t.ir/export_attr.ll
// SYM-DAG: define {{.*}}@_ZN11export_attr5twiceEi(
// SYM-DAG: define {{.*}}@ex_double(
// SYM-DAG: define {{.*}}@ex_sum(
// SYM-DAG: define {{.*}}@ex_self(
// SYM-NOT: wasm-export-name

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/k
// RUN: %t.exe; test $? -eq 21
