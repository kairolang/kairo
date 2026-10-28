// A file named main.k is module `main`: its declarations other than `fn
// main` go inside C++ `namespace main { ... }`, and `fn main` is the global
// `int main` (every input is a module; main is global wherever it is
// declared). Both named `main` at global scope, so clang rejects the TU:
// "redefinition of 'main' as different kind of symbol". A main.k holding
// only `fn main` opens no namespace and works (ffi_c/main.k); so does any
// other file name.
//
// Expected to fail until a module whose C++ namespace would be `main` is
// renamed (as cxx_segment does for keyword segments) or rejected with a
// diagnostic; ticket in private/IMPORTANT/TICKETS.TXT (2026-10-24). When
// it is fixed, lit reports XPASS: drop the XFAIL line and keep the run.

fn helper() -> i32 { return 42 }

fn main() -> i32 {
    return helper()
}

// --- lit wiring -----------------------------------------------------------
// XFAIL: *
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
