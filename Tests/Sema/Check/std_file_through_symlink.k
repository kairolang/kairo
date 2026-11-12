// A std file reached through a symlinked path is still std. The
// passes that ask "is this TU library code?" agree: the default-
// visibility rule (VisibilityFacts), the flag gates,
// the -Wconst-self lint, the panic-set warning and --print-sema all resolve
// symlinks before comparing with the std root, which the driver keeps symlink-free.
// So a std file named through a link was library code to one and the
// user's code to the others: --no-unsafe / --no-ffi denied std's own
// unsafe block and ffi import, -Wconst-self linted std's methods, and
// --print-sema dumped std's lifecycle rows. The std root here is a scratch
// one whose probe.k has all three; it is compiled under its real path and
// through a symlink to the root, with the root given both ways, and (as a
// control that the passes still treat the user's code as the user's) a
// copy outside std through a symlink.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// RUN: rm -rf %t.d && mkdir -p %t.d/std %t.d/user
// RUN: printf 'ffi "c" import "stdint.h"\n\npub class Box {\n    pub var v: i32 = 0\n\n    pub fn get(self) -> i32 {\n        return self.v\n    }\n}\n\npub fn probe() -> i32 {\n    unsafe { return 1 }\n}\n' > %t.d/std/probe.k
// RUN: touch %t.d/std/module.k
// RUN: cp %t.d/std/probe.k %t.d/user/probe.k
// RUN: ln -s %t.d/std %t.d/link
// RUN: ln -s %t.d/user %t.d/ulink
//
// The flag gates.
// RUN: { %kairo --std-dir=%t.d/std --type-check-only --no-unsafe --no-ffi %t.d/std/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=STD --allow-empty
// RUN: { %kairo --std-dir=%t.d/std --type-check-only --no-unsafe --no-ffi %t.d/link/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=STD --allow-empty
// RUN: { %kairo --std-dir=%t.d/link --type-check-only --no-unsafe --no-ffi %t.d/link/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=STD --allow-empty
// STD-NOT: SC198E
//
// The -Wconst-self lint.
// RUN: { %kairo --std-dir=%t.d/std --type-check-only -Wconst-self %t.d/link/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=NOLINT --allow-empty
// NOLINT-NOT: SC273W
//
// --print-sema's lifecycle rows.
// RUN: { %kairo --std-dir=%t.d/std --type-check-only --print-sema %t.d/link/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=NOROWS --allow-empty
// NOROWS-NOT: trivial_copy=
//
// The user's copy, through a symlink: gated, linted and dumped.
// RUN: { %kairo --std-dir=%t.d/std --type-check-only --no-unsafe --no-ffi %t.d/ulink/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=USER
// USER-DAG: probe.k:1:1: error [SC198E]: an ffi import is not allowed when ffi is disabled
// USER-DAG: probe.k:12:5: error [SC198E]: an unsafe block is not allowed when unsafe code is disabled
// RUN: { %kairo --std-dir=%t.d/std --type-check-only -Wconst-self %t.d/ulink/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=LINT
// LINT: probe.k:{{[0-9]+}}:{{[0-9]+}}: warning [SC273W]
// RUN: { %kairo --std-dir=%t.d/std --type-check-only --print-sema %t.d/ulink/probe.k 2>&1 || true; } | %FileCheck %s --check-prefix=ROWS
// ROWS: trivial_copy=
