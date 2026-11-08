// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
//
// An unmarked argument to an `@inout` parameter whose type moves when passed
// (an imported move-only class such as clang::IdentifierTable): arg_info
// turns a MOVE-type lvalue into the xvalue a by-value parameter needs, and
// the `@inout` ranking then saw an xvalue and refused it -- "needs a mutable
// lvalue of type 'MV'; got 'MV'". An `@inout` argument is borrowed, never
// moved from, so it ranks as the lvalue it is. Found in the migrated
// Support/TermRenderer.k (clang_word(ids, ...), self-host phase 5.2).

// DIAG-NOT: error

ffi "c++" import "inout_move_only.h"

fn bump(@inout m: MV) -> i32 {
    m.v += 1
    return m.v
}

fn main() -> i32 {
    var m = MV()
    return bump(&m)
}
