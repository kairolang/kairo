macro text!(x) { stringify!(x) }
macro drop!(x) { 1 }
macro dollar!() { $ }
macro unused!() { $ ` \ }

fn main() -> i32 {
    var a = text!($ ` \)
    var b = drop!($$)
    var x = $129$
    var y = 1 $$` 2
    var z = `x`
    var w = \ 3
    var q = dollar!()
    var h = f"{1 + $}"
    return 0
}

// An ASCII character no token holds (`$`, a backtick, `\` outside a
// literal, DEL) is S011E, once per run of them, where the run reaches the
// parser, and the parser takes the run as a name, so nothing else is
// reported (no S052E "expected expression"). A macro body or argument may
// hold such a run: one that a macro stringifies or drops, or that sits in a
// macro nothing invokes, is not code and is not reported; one that a
// macro's expansion puts into the code is, at its place in the body (line
// 3, listed first: diagnostics come out in source order). So is one in an
// f-string hole.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: illegal_ascii.k:3:19: error [S011E]: character '$' cannot appear outside a string, a character literal or a comment
// CHECK: illegal_ascii.k:9:13: error [S011E]: character '$' cannot appear outside a string, a character literal or a comment
// CHECK: illegal_ascii.k:9:17: error [S011E]: character '$' cannot appear outside a string, a character literal or a comment
// CHECK: illegal_ascii.k:10:15: error [S011E]: character '$' cannot appear outside a string, a character literal or a comment
// CHECK: illegal_ascii.k:11:13: error [S011E]: character '`' cannot appear outside a string, a character literal or a comment
// CHECK: illegal_ascii.k:11:15: error [S011E]: character '`' cannot appear outside a string, a character literal or a comment
// CHECK: illegal_ascii.k:12:13: error [S011E]: character '\' cannot appear outside a string, a character literal or a comment
// CHECK: illegal_ascii.k:14:20: error [S011E]: character '$' cannot appear outside a string, a character literal or a comment
