// A conditional block's members are for the files that declare its paths.
// The block's own file does not (it imports no header), so its
// unconditional code, which exists in every build, cannot use them: with
// the use allowed, the bridge's own translation unit would name
// `std::string`, and the file would stop compiling in a build with no C++
// string. Inside the block the same use is fine.

import self::bridge_outside::*
ffi "c++" import "string"

fn main() -> i32 {
    var s: string = "abc"
    return (ungated(s) as i32) - 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: bridge_outside.k:13:52: error [SC343E]: this uses a member of an extension that exists only where 'cxx::std::string' is declared, from code that exists everywhere; move the use into an extension with the same 'requires' clause
// CHECK-NEXT: bridge_outside.k:2:1: note [SC343N]: the extension is declared here; this file does not declare the path itself
