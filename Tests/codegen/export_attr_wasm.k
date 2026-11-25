// On wasm an `@export(name)` function is also exported from the module under
// `name`: the object carries the export (`wasm-export-name`), so a module
// compiled on its own and linked later exports it too.

@export("render")
pub fn render(n: i32) -> i32 {
    return n * 2
}

@export("kw_self")
ffi "c" fn kw_self(n: i32) -> i32 {
    return n + 1
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-wasm32-wasi
// RUN: rm -rf %t.ir
// RUN: %kairo %s --target=wasm32-wasi --emit=llvm-ir --cache-dir %t.ir
// RUN: %FileCheck %s --check-prefix=IR < %t.ir/export_attr_wasm.ll
// IR-DAG: define {{.*}}@render({{.*}} #[[R:[0-9]+]]
// IR-DAG: define {{.*}}@kw_self({{.*}} #[[S:[0-9]+]]
// IR-DAG: attributes #[[R]] = {{.*}}"wasm-export-name"="render"
// IR-DAG: attributes #[[S]] = {{.*}}"wasm-export-name"="kw_self"
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --target=wasm32-wasi -o %t.d/a.wasm
// RUN: test -s %t.d/a.wasm
