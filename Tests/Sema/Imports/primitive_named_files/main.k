// A file named like a primitive type can be imported. `f8`, `i32` and
// `bool` lex as type keywords, and `import self::f8::*` is not S046E "expected
// a module path after 'self::'". An import path segment is a name: every
// primitive type's word is accepted there (`string` is a plain identifier
// and always worked). The one place the word still cannot go is the name
// an import BINDS: `import self::i32` would bind `i32`, and `i32::f()`
// names the primitive type, so that is S046E with a fix-it adding an `as`
// name (bound_word.k). Wildcards, symbol imports, `as` and selective
// lists bind other names and are fine.

import self::f8::*
import self::i32 as i32_mod
import self::string::*
import self::bool::from_bool
import self::bool::{from_bool as fb}
import self::sub::u8::deep
import self::sub::u8 as eight

fn main() -> i32 {
    return from_f8() + i32_mod::from_i32() + from_string() + from_bool() + fb() + deep() + eight::deep() - 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
// RUN: %t.exe
// RUN: { %kairo %S/bound_word.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BOUND --implicit-check-not="error ["
// BOUND: bound_word.k:1:14: error [S046E]: an import cannot bind the name 'i32': it is a primitive type, so 'i32::' names the type, not this module; give it another name with 'as', or import its contents with '::*'
// BOUND-NEXT: fix-it:"{{.*}}bound_word.k":{1:17-1:17}:" as i32_mod"
// BOUND: bound_word.k:2:19: error [S046E]: an import cannot bind the name 'u8': it is a primitive type, so 'u8::' names the type, not this module; give it another name with 'as', or import its contents with '::*'
// BOUND-NEXT: fix-it:"{{.*}}bound_word.k":{2:21-2:21}:" as u8_mod"
