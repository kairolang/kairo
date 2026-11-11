// `T? -> U?` where the inner types convert implicitly: Sema accepts
// `var b: i64? = find(3)` (find -> i32?) and `*Dog? -> *Animal?`, so the
// program must build: null stays null, a value converts.
//
// Nullable has no converting constructor, so a static_cast would be
// CL001E in clang. EmitIR
// tests the source once and converts only the value
// (EmitIR::_nullable_convert); Tests/Codegen/nullable/pointer_convert.k
// covers the pointer cases.

fn find(k: i32) -> i32? {
    if k > 0 { return k }
    return null
}

class Animal { virtual fn legs(const self) -> i32 { return 4 } }
class Dog derives Animal { }

fn main() -> i32 {
    var b: i64? = find(3)
    var n: i64? = find(0)
    var d = Dog()
    var pd: *Dog? = &d
    var pa: *Animal? = pd
    var r = 0
    if b === 3 { r += 1 }
    if !n? { r += 2 }
    if pa? { r += pa->legs() }                  // 4
    return r                                    // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
