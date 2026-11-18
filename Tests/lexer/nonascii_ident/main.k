// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NODIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
// A non-ASCII identifier hashes the same in the lexer and in the
// interner's lookups, so it resolves across files as well as within one.
// NODIAG-NOT: error
import lib

fn année() -> i32 {
    return 0
}

fn main() -> i32 {
    return lib::plain() + lib::naïve() + année()
}
