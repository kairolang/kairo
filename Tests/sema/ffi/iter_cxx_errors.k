// When a C++ class cannot be ranged over. [stmt.ranged]: a member `begin`
// alone is an error, not a fallback to free functions; a class with no
// member begin/end whose namespace has free ones for OTHER types is simply
// not iterable (the free `begin(Free&)` cannot take it), and the message
// names both protocols Kairo knows.

ffi "c++" import "iter_cxx_errors.h"

fn f(a: ie::OnlyBegin, c: ie::Plain) {
    for x in a { }
    for x in c { }
}

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      iter_cxx_errors.k:10:14: error [SC095E]: 'OnlyBegin' has a member 'begin' but no 'end'; a C++ range needs both
// DIAG-NEXT: iter_cxx_errors.k:11:14: error [SC095E]: 'Plain' is not iterable; it has no 'op in (self) -> yield T' and no 'begin()'/'end()'
// DIAG-NOT:  {{error|warning}} [
