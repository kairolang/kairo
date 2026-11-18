// The pretty renderer's source-line highlighter colours every word token that
// is a keyword or builtin type name the same way (the keyword colour
// 38;2;250;121;112): `byte`, `mutable`, `bf16`, `f8e4m3`, `f512`, not just
// `i32`, `fn` and `var`. A plain identifier on the same line carries no
// keyword colour.
//
// The diagnostic is rendered to a pseudo-terminal so colour is on; the
// escapes are printed as <E>.

fn main() -> i32 {
    mutable var a: bf16 = undefined_name; var b: f8e4m3 = 0; var c: f512 = 0; var d: byte = 0; var e: i32 = 0
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell, host-linux
// RUN: { python3 %S/inputs/pty_capture.py %kairo %s --type-check-only --error-format=pretty || true; } > %t.out
// RUN: %FileCheck %s < %t.out
// CHECK: <E>[38;2;250;121;112mmutable<E>[0m
// CHECK: <E>[38;2;250;121;112mbf16<E>[0m
// CHECK: <E>[38;2;250;121;112mf8e4m3<E>[0m
// CHECK: <E>[38;2;250;121;112mf512<E>[0m
// CHECK: <E>[38;2;250;121;112mbyte<E>[0m
// CHECK: <E>[38;2;250;121;112mi32<E>[0m
// RUN: not grep -F '250;121;112mundefined_name' %t.out
