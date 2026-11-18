// `#name` names a C++ entity whose name is a Kairo keyword: `thread`,
// `yield` and `byte` cannot be written bare after `::`, so
// `cxx::std::thread` was S054E and the Stage 0 compiler's libcxx::thread
// sites had no Stage 1 spelling. The `#` is dropped only when the exact
// spelling is absent, so a Kairo name declared with the `#` keeps it.

ffi "c++" import "<thread>"
ffi "c++" import "<cstddef>"

fn main() -> i32 {
    var n = cxx::std::#thread::hardware_concurrency()
    cxx::std::this_thread::#yield()
    var b: cxx::std::#byte = 7u8 as cxx::std::#byte
    var #in = 3
    if n == 0 { return 1 }
    return ((b as u8) as i32) + #in - 10
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 0
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
