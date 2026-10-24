// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// A multi-segment pin: this directory is library `acme::tools`.
//
// CHECK-NOT: error

module acme::tools   // the pin may carry a trailing comment
