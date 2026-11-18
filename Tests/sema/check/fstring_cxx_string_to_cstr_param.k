// An f-string is a Kairo `string`, not a literal: it does not convert to an
// imported `const char*` parameter implicitly. The error is the ordinary
// SC063E overload mismatch with a `.c_str()` fix-it, not a generic-body
// diagnostic (SC080E).

import std
ffi "c++" import "<cstring>"

var n: i32 = 42
var len: usize = strlen(f"{n}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: fstring_cxx_string_to_cstr_param.k:10:18: error [SC063E]: no matching overload for call to 'strlen'
