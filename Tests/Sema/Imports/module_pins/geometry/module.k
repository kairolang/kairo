// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// The library's entry point, and the bare `module` declaration in a module.k
// (Bugs/Triage F27): it pins this directory as library `geo`, whatever the
// folder is called. Run on its own it must still parse; main.k checks what
// the pin means.
//
// CHECK-NOT: error

module geo

pub import shapes
