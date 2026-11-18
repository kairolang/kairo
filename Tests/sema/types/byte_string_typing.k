// A byte string is a `[const u8;]` and nothing else: it converts where a
// read-only slice does, and nowhere a `string`, a writable slice or a
// pointer is wanted. Nothing writes through it, a C string parameter does
// not take it, and it is not an eval value yet.

ffi "c++" import "cstring"

fn take(xs: [const u8;]) -> usize {
    return xs.len
}

fn take_string(const s: string) -> usize {
    return s.length()
}

eval fn in_eval() -> u8 {
    var s = b"q"
    return s[0]
}

fn ok() -> usize {
    var s = b"ab"
    var t: [const u8;] = b"cd"
    return take(b"ef") + s.len + t.len
}

fn bad() {
    var as_string: string = b"x"
    var writable: [u8;] = b"x"
    var pointer: *const u8 = b"x"
    var s = b"ab"
    s[0] = 1
    take_string(b"x")
    strlen(b"x")
    eval E: [const u8;] = b"x"
    match s {
        case b"ab" { }
        default { }
    }
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}:17:14: error [SC116E]: a byte string in an eval context is not yet supported
// CHECK: {{.*}}:28:30: error [SC028E]: cannot convert '[const u8;]' to 'string'
// CHECK: {{.*}}:29:28: error [SC028E]: cannot convert '[const u8;]' to '[u8;]'
// CHECK: {{.*}}:30:31: error [SC028E]: cannot convert '[const u8;]' to '*const u8'; take the address with '&'
// CHECK: {{.*}}:32:5: error [SC071E]: cannot assign to a const place
// CHECK: {{.*}}:33:5: error [SC063E]: no matching overload for call to 'take_string'
// CHECK: {{.*}}:34:5: error [SC063E]: no matching overload for call to 'strlen'
// CHECK: {{.*}}:35:10: error [SC116E]: an 'eval' constant of slice type '[const u8;]' is not yet supported: a slice has no compile-time form; declare 'E' as a fixed array
// CHECK: {{.*}}:37:15: error [SC066E]: no 'op ==' on '[const u8;]'; a record compares only through its own operator
//
// The literal's type, and the tree's mark for it.
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: StringLiteralExpr       @ 22:14    : [const u8;]
// SEMA: StringLiteralExpr       @ 23:27    : [const u8;]
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=TREE
// TREE: StringLiteralExpr "ab" bytes
