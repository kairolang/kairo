ffi r"c++" import "numeric"
ffi "c++" import b"numeric"
ffi "c++" import f"numeric"
ffi "c++" import rf"numeric"
ffi b"c" { fn abs(x: i32) -> i32 }

fn main() -> i32 {
    unsafe {
        inline r"asm" { nop }
    }

    return cxx::std::gcd(12, 18) + abs(-1)
}

// An ffi language and an inline block's language are plain strings, and an
// ffi header path is a plain or a raw string (a raw one spells a Windows
// path without doubled backslashes; Inputs-free coverage of that is in
// ffi_raw_header_path.k): a prefix they do not take is S064E (S060E after
// `inline`) with a fix-it that removes it. The import still resolves, so
// the names the header declares do not cascade. A prefix that keeps a
// letter the path takes (`rf`) gets no fix-it.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="fix-it:"
// CHECK: ffi_prefixed_strings.k:1:5: error [S064E]: the language of 'ffi' is a plain string; remove the 'r' prefix
// CHECK-NEXT: fix-it:"{{.*}}ffi_prefixed_strings.k":{1:5-1:6}:""
// CHECK: ffi_prefixed_strings.k:2:18: error [S064E]: an ffi header path is a plain or raw string; remove the 'b' prefix
// CHECK-NEXT: fix-it:"{{.*}}ffi_prefixed_strings.k":{2:18-2:19}:""
// CHECK: ffi_prefixed_strings.k:3:18: error [S064E]: an ffi header path is a plain or raw string; remove the 'f' prefix
// CHECK-NEXT: fix-it:"{{.*}}ffi_prefixed_strings.k":{3:18-3:19}:""
// CHECK: ffi_prefixed_strings.k:4:18: error [S064E]: an ffi header path is a plain or raw string; remove the 'f' prefix
// CHECK: ffi_prefixed_strings.k:5:5: error [S064E]: the language of 'ffi' is a plain string; remove the 'b' prefix
// CHECK-NEXT: fix-it:"{{.*}}ffi_prefixed_strings.k":{5:5-5:6}:""
// CHECK: ffi_prefixed_strings.k:9:16: error [S060E]: the language of 'inline' is a plain string; remove the 'r' prefix
// CHECK-NEXT: fix-it:"{{.*}}ffi_prefixed_strings.k":{9:16-9:17}:""
