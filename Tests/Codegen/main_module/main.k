// A file named main.k is module `main`: its declarations other than `fn
// main` go inside its C++ namespace, and `fn main` is the global `int main`.
// Both named `main` at global scope used to make clang reject the TU
// ("redefinition of 'main' as different kind of symbol"). Since the fix a top
// namespace segment that is taken (an entry point, a header global, another
// module) is renamed by appending `_`, so this namespace is `main_` and the
// program runs.

fn helper() -> i32 { return 42 }

fn main() -> i32 {
    return helper()
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
