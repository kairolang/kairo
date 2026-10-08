// `ffi "c"` on a Kairo-DEFINED function gives it C linkage: the symbol is
// the bare name, not the namespace-mangled one, so a C caller or a linker
// script (`LONG(Reset_Handler)` in a vector table) can name it. `extern "C"`
// leads the declaration and the definition both. The backend also passes
// -fno-finite-loops, so `loop {}` is never assumed to terminate and the
// IR carries no `mustprogress`.

ffi "c" fn kairo_exported(x: i32) -> i32 { return x + 1 }

ffi "c" fn kairo_halt() -> ! {
    loop { }
}

fn main() -> i32 {
    return kairo_exported(41)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=DECL
// DECL-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}ffi_c_export.k
// DECL: {{^ *}}extern "C" signed int kairo_exported(signed int x);
// DECL: {{^ *}}extern "C"{{ ?}}{{\[\[noreturn\]\]}} void kairo_halt();

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=DEF
// DEF-LABEL: CODEGEN C++: {{.*}}ffi_c_export.k
// DEF: {{^ *}}extern "C" signed int kairo_exported(signed int x)
// DEF: {{^ *}}extern "C" void kairo_halt()

// RUN: rm -rf %t.ir
// RUN: %kairo %s --emit=llvm-ir --cache-dir %t.ir
// RUN: %FileCheck %s --check-prefix=SYM < %t.ir/ffi_c_export.ll
// SYM-DAG: define {{.*}}@kairo_exported(
// SYM-DAG: define {{.*}}@kairo_halt()
// RUN: not grep -q mustprogress %t.ir/ffi_c_export.ll

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 42
