// packs/empty_pack_for.k -- exit 0 (P258)
// `for x in xs` over an empty pack: the `&&` fold over no elements is the
// bare `true`, which as a statement was clang's "expression result unused"
// (C1119W at the `for`). The fold is spelled `(void)(... && ...)`.

fn <...T> count(...args: T) -> i32 {
    var n = 0
    for arg in args { n += 1 }
    return n
}

fn main() -> i32 {
    if count() != 0      { return 1 }
    if count(1, 2.0) != 2 { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: (void)(... &&[&]({{\[\[}}maybe_unused{{\]\]}} auto & arg)->bool {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{warning|error}}
// RUN: %t.exe
