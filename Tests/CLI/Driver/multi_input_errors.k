// RUN: { %kairo %s %S/Inputs/multi_input_errors/second.k %S/Inputs/multi_input_errors/third.k --type-check-only 2>&1 || true; } | %FileCheck %s
// RUN: not %kairo %s %S/Inputs/multi_input_errors/second.k --type-check-only > /dev/null 2>&1
//
// Several inputs are each checked even after one fails, as clang does:
// every input's errors are reported and the batch fails if any did. The
// per-input gates compared the SHARED engine's error count with zero, so
// once this file had an error every later input stopped right after its
// parse and its own errors were never reported.

fn first() -> i32 {
    // CHECK: multi_input_errors.k:[[@LINE+1]]:12: error [R020E]: use of undeclared identifier 'missing_in_first'
    return missing_in_first
}

// CHECK: second.k:3:12: error [R020E]: use of undeclared identifier 'missing_in_second'
// CHECK-NOT: third.k{{.*}}error
