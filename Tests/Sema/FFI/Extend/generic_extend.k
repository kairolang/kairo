// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Typing a generic extension body over an IMPORTED template. Inside `extend <T> cont<T>`, `self` is the PATTERN, and the pattern's
// `size()` returns its dependent `size_type`, which reaches the typer as an
// opaque `<ffi type>`: `self.size() / 2` is then rejected with
// "no operator '/' for operands '<ffi type>' and 'i32'" instead of being
// deferred to each instance (RESOLUTION.md invariant #5). Since the fix a member
// call on a dependent C++ instance is decided per instance, and `a.halved()`
// on the concrete `cont<i32>` is u64.

ffi "c++" import "../traits_typedef.h"

interface <T> Div { // with or without this should be working
    fn op / (self, other: T) -> T
}

extend <T impl Div<T>> cont<T> {
    fn halved(self) -> u64 { return self.size() / 2 }
}

fn use() -> u64 {
    var a: cont<i32>
    var h = a.halved()
    return h
}

// DIAG-NOT: error
// SEMA-DAG: h : u64
