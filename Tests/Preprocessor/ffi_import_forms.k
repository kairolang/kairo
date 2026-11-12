// An ffi import names ONE header (imports.mdx "FFI Header Imports",
// c-cpp-calling.mdx). `ffi "c++" import {"a.h", "nope.h"}` was accepted:
// the preprocessor took the first string, dropped the rest of the line
// unread, and never looked for "nope.h". A brace list, two adjacent header
// strings (one chained token), or anything else after the header but
// `as name`, is now S064E, and that line imports nothing. A lone `ffi`
// line took the newline as its language and the next line's `import "h"`
// as its own, silently: the language string must follow `ffi` on its line
// (S064E from the parser).

ffi "c++" import {"vector", "nope.h"}
ffi "c++" import {
    "vector",
    "nope.h"
}
ffi "c++" import "vector" "nope.h"
ffi "c++" import "vector" junk
ffi "c++" import "vector" as
ffi "c++" import
ffi
import "vector"

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK-DAG: ffi_import_forms.k:11:18: error [S064E]: an ffi import takes one header, not a list; write one 'ffi "c++" import "header"' line per header
// CHECK-DAG: ffi_import_forms.k:12:18: error [S064E]: an ffi import takes one header, not a list; write one 'ffi "c++" import "header"' line per header
// CHECK-DAG: ffi_import_forms.k:16:18: error [S064E]: an ffi import takes one header, not a list; write one 'ffi "c++" import "header"' line per header
// CHECK-DAG: ffi_import_forms.k:17:27: error [S064E]: unexpected token in an ffi import; the form is 'ffi "c++" import "header"', optionally followed by 'as name'
// CHECK-DAG: ffi_import_forms.k:18:27: error [S064E]: expected a name after 'as' in ffi import
// CHECK-DAG: ffi_import_forms.k:19:1: error [S064E]: expected a header path string after 'ffi "..." import'
// CHECK-DAG: ffi_import_forms.k:20:1: error [S064E]: expected a language string after 'ffi' (e.g. "c++")
// CHECK-DAG: ffi_import_forms.k:21:1: error [S046E]: expected a module or symbol path after 'import'
