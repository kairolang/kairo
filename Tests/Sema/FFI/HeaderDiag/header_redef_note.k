// clang's trailing note attaches to its primary, and both resolve into
// the header: the note points at the first definition.

ffi "c++" import "redef.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      redef.h:2:5: error [CL001E]: redefinition of 'hd_redef'
// DIAG-NEXT: redef.h:1:5: note [{{[A-Z]+[0-9]+}}N]: previous definition is here
// DIAG-NOT:  {{error|warning}} [
