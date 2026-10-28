// What std::c_char refuses. A C string is `*const c_char`, and bytes become
// C chars only by reinterpreting the pointer (casting.mdx: pointers to
// unrelated types need `as unsafe *`), so a `*u8` (a string's `data`) or a
// `*i8` passed to a `const char*` parameter is an error whose fix-it is that
// cast. `signed char` is still i8 and takes one. As a value c_char is a
// character, not a number: a literal must be 0..=127 (both signednesses of
// C's char agree there), it does no arithmetic, and it converts to an
// integer only with `as`.

import std::c_char

ffi "c++" import "c_char_errors.h"

fn main() -> i32 {
    var s = "hi"
    var b: [i8; 2]
    unsafe {
        var x = take(s.data)
        var y = take(unsafe &b[0])
        var ok = take_signed(unsafe &b[0])
        var ok2 = take(s.data as unsafe *const c_char)
    }
    var c: c_char = 200
    var d: c_char = -1
    var e: c_char = 127
    var f = e + e
    var g: i8 = e
    var h = e as i8
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:18:17: error [SC063E]: no matching overload for call to 'take'
// DIAG-NEXT: fix-it:"{{.*}}":{18:28-18:28}:" as unsafe *const c_char"
// DIAG-NEXT: {{.*}}/c_char_errors.h:4:1: note [I900N]: candidate not viable: cannot convert argument of type '*const u8' to parameter 's' of type 'unsafe *const c_char'; a C string is '*const c_char' (std::c_char), which no byte or i8 pointer converts to
// DIAG: {{.*}}:19:17: error [SC063E]: no matching overload for call to 'take'
// DIAG-NEXT: fix-it:"{{.*}}":{19:34-19:34}:" as unsafe *const c_char"
// DIAG-NEXT: {{.*}}/c_char_errors.h:4:1: note [I900N]: candidate not viable: cannot convert argument of type 'unsafe *i8' to parameter 's' of type 'unsafe *const c_char'; a C string is '*const c_char' (std::c_char), which no byte or i8 pointer converts to
// DIAG: {{.*}}:23:21: error [SC075E]: literal '200' does not fit in 'c_char' on every target: only 0 through 127 do, whether C's char is signed or not
// DIAG: {{.*}}:24:22: error [SC075E]: literal '1' does not fit in 'c_char' on every target: only 0 through 127 do, whether C's char is signed or not
// DIAG: {{.*}}:26:13: error [SC067E]: arithmetic requires numeric operands, not 'c_char' and 'c_char'
// DIAG: {{.*}}:27:17: error [SC028E]: cannot convert 'c_char' to 'i8'; the conversion may lose value and needs an explicit 'as'
// END-GENERATED-CHECKS(DIAG)
