// What `f8e4m3` / `f8e5m2` do not do yet, said by Kairo rather than by
// clang. Their C++ classes (std/rt/Float8.k) are no literal types, so an f8
// value in an eval context is SC116E as f256's is; and f256 / f512 are
// classes the f8 classes do not know, so a conversion between them, which
// clang found ambiguous, is SC116E with the route through f32 or f64.

eval E: f8e4m3 = 1.0

fn wide(x: f8e5m2) -> f256 { return x as f256 }

fn narrow(x: f512) -> f8e4m3 { return x as f8e4m3 }

fn fine(x: f256) -> f8e4m3 { return (x as f64) as f8e4m3 }

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK-DAG: f8_unsupported.k:7:18: error [SC116E]: an 'f8e4m3' value in an eval context is not yet supported
// CHECK-DAG: f8_unsupported.k:9:37: error [SC116E]: a conversion between 'f8e5m2' and 'f256' is not supported yet; convert through 'f32' or 'f64' with 'as'
// CHECK-DAG: f8_unsupported.k:11:39: error [SC116E]: a conversion between 'f512' and 'f8e4m3' is not supported yet; convert through 'f32' or 'f64' with 'as'
