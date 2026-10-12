// Corpus for main.k: an enum declared in another Kairo module.

pub enum Compass { North, East, South, West }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: {{error|warning}}
