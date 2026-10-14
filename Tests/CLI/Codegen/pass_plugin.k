// --pass-plugin is -fpass-plugin=<path>, applied by clang's backend when it
// builds the pipeline. A file that does not exist is an error.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --pass-plugin=%s || true; } | %FileCheck %s --check-prefix=OK
// OK: -fpass-plugin={{[^ ]*}}pass_plugin.k
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --pass-plugin=/nonexistent/p.so 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U001E]: --pass-plugin: no such plugin file '/nonexistent/p.so'
