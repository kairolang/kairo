// The driver registers std as `kairo::std` spelled `std`, and builtin as
// `builtin`. Naming one of those directories again with -I is the same
// directory twice, and the explicit registration wins whatever the order:
// the duplicate -I is folded into it. Before, the user's -I came first,
// took the directory's own pin, and the driver's registration was dropped
// as a duplicate -- std lost its `std` spelling (`import std::io` was
// R011E) and builtin became a discovered library without the last-resort
// probe (`Lib/std/io.k`'s bare `string` was R011E). Nothing said why.

import std::io

fn use_io() -> void {
    io::println("x")
}

// --- lit wiring -----------------------------------------------------------
// The directories exactly as lit's --builtins-dir/--std-dir spell them, and
// through a `..` spelling (the same directory, compared by real path).
// RUN: %kairo %s --type-check-only -I "$(cd %S/../../../Lib/std && pwd)"
// RUN: %kairo %s --type-check-only -I "$(cd %S/../../../Lib/builtin && pwd)"
// RUN: %kairo %s --type-check-only -I %S/../../../Lib/builtin -I %S/../../../Lib/std -I %S/../../../Lib

// The registration is checked against the directory's own pin: a std dir
// whose module.k says something else is told so, not silently renamed.
// RUN: { %kairo %S/Inputs/std_pin_mismatch/module.k --type-check-only --std-dir=%S/Inputs/std_pin_mismatch 2>&1 || true; } | %FileCheck %s --check-prefix=MISMATCH
// MISMATCH: error [R001E]: '{{.*}}std_pin_mismatch/module.k' pins `module not_std`, but this directory is registered as library 'kairo::std'
