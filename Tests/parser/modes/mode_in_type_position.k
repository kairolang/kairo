var g: @inout i32 = 0;                      // expect: error mode-in-type
fn r() -> @move i32 { return 0; }           // expect: error mode-in-type
fn t(x: (i32, @inout i32)) { }              // expect: error mode-in-type
fn u(x: fn(i32) -> @inout i32) { }          // expect: error mode-in-type (return position)
fn v(x: Box<@inout i32>) { }                // expect: error mode-in-type
fn w(x: @inout i32) { }                     // expect: error mode-in-type (mode after the colon is a type position)
// expect: exactly 6 errors

// --- lit wiring -----------------------------------------------------------
// A mode is not part of a type. The one type-shaped place it may appear is a
// fn-pointer's PARAMETER position (fnptr_modes.k); its return position, a
// tuple element, a generic argument and a parameter's type after the colon
// are all type positions.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// DIAG:     mode_in_type_position.k:1:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_in_type_position.k:2:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_in_type_position.k:3:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_in_type_position.k:4:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_in_type_position.k:5:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG:     mode_in_type_position.k:6:{{[0-9]+}}: error [{{[A-Z0-9]+}}]:
// DIAG-NOT: error [
