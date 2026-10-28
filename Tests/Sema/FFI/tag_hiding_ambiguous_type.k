// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// tag_hiding_ambiguous.k's collision reached from a TYPE position: T
// reports the same use-site R016E N does for a value.

ffi "c++" import "Inputs/tag_hiding/ambiguous.h"

fn type_use(p: dup) -> i32 {
    return 0
}

// DIAG-NOT: tag_hiding_ambiguous_type.k:6:{{.*}}error
// DIAG:      tag_hiding_ambiguous_type.k:8:16: error [R016E]: ambiguous import: 'dup' names more than one non-function symbol
// DIAG-NEXT: ambiguous.h:3:23: note [R016N]: 'dup' could be the variable declared here
// DIAG-NEXT: ambiguous.h:4:23: note [R016N]: 'dup' could be the typedef declared here
