// P301: only a string LITERAL is its own C string. A `string` that is not
// one passes its bytes with `.c_str()`, the fix-it, at a `const char *`
// parameter and at C's `...` tail (where a C++ class cannot go at all).
// A `char *` may be written, and a literal's bytes are read-only. A Kairo
// function's own `*const u8` parameter keeps its rules: the conversion is
// at imported functions only.

ffi "c" import "stdio.h"
ffi "c++" import "c_string_literal_errors.h"

fn takes_bytes(p: *const u8) -> u8 { return *p }

fn main() {
    var s = "abc"
    var n = count(s)
    printf("%s\n", s)
    fill("x")
    var b = takes_bytes("x")
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:15:13: error [SC063E]: no matching overload for call to 'count'
// DIAG-NEXT: fix-it:"{{.*}}":{15:20-15:20}:".c_str()"
// DIAG-NEXT: {{.*}}/c_string_literal_errors.h:5:1: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter 's' of type 'unsafe *const c_char'; a string other than a literal passes its bytes with '.c_str()'
// DIAG: {{.*}}:16:20: error [SC245E]: a 'string' cannot pass through C's '...'; pass its bytes as a C string with '.c_str()'
// DIAG-NEXT: fix-it:"{{.*}}":{16:21-16:21}:".c_str()"
// DIAG: {{.*}}:17:5: error [SC063E]: no matching overload for call to 'fill'
// DIAG-NEXT: {{.*}}/c_string_literal_errors.h:4:1: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter 'buf' of type 'unsafe *c_char'
// DIAG: {{.*}}:18:13: error [SC063E]: no matching overload for call to 'takes_bytes'
// DIAG-NEXT: {{.*}}:11:1: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter 'p' of type '*const u8'
// END-GENERATED-CHECKS(DIAG)
