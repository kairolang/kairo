// An `inline` function with no body is reported wherever it is declared:
// a visibility group, an `eval` block and an `ffi` block declare into the
// scope they sit in, so the rule reaches through each of them as it does
// for a declaration written directly at file scope.

inline fn plain() -> i32

pub {
    inline fn in_group() -> i32
}

eval {
    inline fn in_eval() -> i32
}

ffi "c" inline fn single_ffi(x: i32) -> i32

ffi "c" {
    inline fn in_ffi(x: i32) -> i32
    fn declared_only(x: i32) -> i32
}

module m {
    eval {
        inline fn in_module_eval() -> i32
    }
}

inline fn defined() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: {{.*}}:6:1: error [R062E]: 'plain' is declared inline but has no body
// DIAG: {{.*}}:9:5: error [R062E]: 'in_group' is declared inline but has no body
// DIAG: {{.*}}:13:5: error [R062E]: 'in_eval' is declared inline but has no body
// DIAG: {{.*}}:16:9: error [R062E]: 'single_ffi' is declared inline but has no body
// DIAG: {{.*}}:19:5: error [R062E]: 'in_ffi' is declared inline but has no body
// DIAG: {{.*}}:25:9: error [R062E]: 'in_module_eval' is declared inline but has no body
