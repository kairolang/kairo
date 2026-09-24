// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// XFAIL: *
//
// WAITING ON: typing a generic extension body over an IMPORTED template.
// Inside `extend <T> cont<T>`, `self` is the PATTERN, and the pattern's
// `size()` returns its dependent `size_type`, which reaches the typer as an
// opaque `<ffi type>`: `self.size() / 2` is then rejected with
// "no operator '/' for operands '<ffi type>' and 'i32'" instead of being
// deferred to each instance (RESOLUTION.md invariant #5). When this XPASSes,
// replace the XFAIL with a SEMA check that `a.halved()` is u64.

ffi "c++" import "../traits_typedef.h"

extend <T> cont<T> {
    fn halved(self) -> u64 { return self.size() / 2 }
}

fn use() -> u64 {
    var a: cont<i32>
    return a.halved()
}

// DIAG-NOT: error
