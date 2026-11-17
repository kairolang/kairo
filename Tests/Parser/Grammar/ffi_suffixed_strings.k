ffi "c++"_x import "numeric"
ffi "c++" import "numeric"_y
ffi "c"_z { fn abs(x: i32) -> i32 }

fn main() -> i32 {
    unsafe {
        inline "asm"_w { nop }
    }

    return cxx::std::gcd(12, 18) + abs(-1)
}

// An ffi language, an ffi header path and an inline block's language take
// no literal suffix: a suffix names a literal operator over a value, and
// these strings are not values. Each is S064E (S060E after `inline`) with
// a fix-it that removes the suffix. The import still resolves, so the
// names the header declares do not cascade, and each suffix is reported
// once.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="fix-it:"
// CHECK: ffi_suffixed_strings.k:1:10: error [S064E]: the language of 'ffi' is a plain string; remove the suffix
// CHECK-NEXT: fix-it:"{{.*}}ffi_suffixed_strings.k":{1:10-1:12}:""
// CHECK: ffi_suffixed_strings.k:2:27: error [S064E]: an ffi header path takes no suffix; remove it
// CHECK-NEXT: fix-it:"{{.*}}ffi_suffixed_strings.k":{2:27-2:29}:""
// CHECK: ffi_suffixed_strings.k:3:8: error [S064E]: the language of 'ffi' is a plain string; remove the suffix
// CHECK-NEXT: fix-it:"{{.*}}ffi_suffixed_strings.k":{3:8-3:10}:""
// CHECK: ffi_suffixed_strings.k:7:21: error [S060E]: the language of 'inline' is a plain string; remove the suffix
// CHECK-NEXT: fix-it:"{{.*}}ffi_suffixed_strings.k":{7:21-7:23}:""
