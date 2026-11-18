// Every member binding form declares its type: `const`, `static
// const` and `eval` members with an initializer and no type are errors,
// not left for InterfaceEmitter, and so is a bare `var b` (never a `void` field). The
// shorthands keep their own message and are not reported twice.

class C {
    const a = 5
    static const s = 1
    eval e = 2
    var b
    var q? = 3
    pub var ok: i32 = 4
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: field_without_type_forms.k:7:11: error [S058E]: a field declares its type; write 'a: T'
// CHECK: field_without_type_forms.k:8:18: error [S058E]: a field declares its type; write 's: T'
// CHECK: field_without_type_forms.k:9:10: error [S058E]: a field declares its type; write 'e: T'
// CHECK: field_without_type_forms.k:10:9: error [S058E]: a field declares its type; write 'b: T'
// CHECK: field_without_type_forms.k:11:10: error [S058E]: a field declares its type and cannot use the '?' shorthand
