// `ffi "c++"` on one line and what it applies to on the next. The
// language string stamped C++ linkage on whatever declaration followed it
// (`fn main` lost its C entry), and an `import "h"` there was S046E
// "expected a module or symbol path after 'import'". Every documented form
// (imports.mdx "FFI Header Imports" and "FFI Linkage Declarations",
// c-cpp-calling.mdx) keeps `ffi "lang"` and its import, declaration or
// block on one line, so a line break there is S064E, with a fix-it that
// joins the lines; the rest is then read as joined, so the import still
// imports and nothing cascades. The same-line forms are unchanged.

ffi "c++"
import "vector"
ffi "c"

fn shout(x: i32) -> i32
ffi "c"
{
    fn whisper(x: i32) -> i32
}
ffi "c" fn hum(x: i32) -> i32
ffi "c++" import "utility"

fn main() -> i32 {
    var v = cxx::std::vector<i32>()
    v.push_back(1)
    return (v.size() as i32) - 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: ffi_lang_string_newline.k:11:5: error [S064E]: the declaration, block or import an ffi language string applies to must follow it on the same line
// CHECK-NEXT: fix-it:"{{.*}}ffi_lang_string_newline.k":{11:10-12:1}:" "
// CHECK: ffi_lang_string_newline.k:13:5: error [S064E]: the declaration, block or import an ffi language string applies to must follow it on the same line
// CHECK-NEXT: fix-it:"{{.*}}ffi_lang_string_newline.k":{13:8-15:1}:" "
// CHECK: ffi_lang_string_newline.k:16:5: error [S064E]: the declaration, block or import an ffi language string applies to must follow it on the same line
// CHECK-NEXT: fix-it:"{{.*}}ffi_lang_string_newline.k":{16:8-17:1}:" "
