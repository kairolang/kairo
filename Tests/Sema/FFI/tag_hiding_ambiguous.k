// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// Two ORDINARY header names in one scope are a real ambiguity, but C++
// reports it where the name is USED, not where the header is included: the
// import line is clean, and each use is an R016E with one note per
// candidate (a type use: tag_hiding_ambiguous_type.k). A collision any
// Kairo import takes part in stays eager, at the import
// (Tests/Sema/Imports/per_form/main_ambiguous.k).

ffi "c++" import "Inputs/tag_hiding/ambiguous.h"

fn value_use() -> i32 {
    var x = dup
    return 0
}

// DIAG-NOT: tag_hiding_ambiguous.k:10:{{.*}}error
// DIAG:      tag_hiding_ambiguous.k:13:13: error [R016E]: ambiguous import: 'dup' names more than one non-function symbol
// DIAG-NEXT: ambiguous.h:3:23: note [R016N]: 'dup' could be the variable declared here
// DIAG-NEXT: ambiguous.h:4:23: note [R016N]: 'dup' could be the typedef declared here
