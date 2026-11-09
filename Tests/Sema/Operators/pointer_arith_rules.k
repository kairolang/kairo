// The builtin operators on pointers (pointers.mdx, Pointer
// Arithmetic). `p + n` / `p - n` take any integer and keep the pointer
// type, on both kinds; `p += n` too. `p - q` is isize, raw pointers only.
// `<` `<=` `>` `>=` take two pointers of one type, either kind.

fn safe_ok(p: *i32, q: *i32, n: usize, m: i8) -> bool {
    var a: *i32 = p + n
    var b: *i32 = p - m
    var *c = p + 1
    var *d = q
    d += 2
    d -= n
    return (a < b) && (c <= d) && (p > q) && (p >= q)
}

fn raw_ok(p: unsafe *u8, q: unsafe *u8, r: unsafe *const u8, n: usize) -> isize {
    var a: unsafe *u8 = p + n
    var lo = (a < q) || (q >= r)
    var d: isize = a - q
    return d
}

fn safe_diff(p: *i32, q: *i32) -> isize {
    return p - q
}

fn mixed_kinds(p: *i32, q: unsafe *i32) -> bool {
    return p < q
}

fn mixed_pointees(p: unsafe *i32, q: unsafe *i64) -> isize {
    return p - q
}

fn void_offset(v: unsafe *void) -> unsafe *void {
    return v + 1
}

fn not_an_int(p: *i32) -> *i32 {
    return p + 1.5
}

fn two_sums(p: *i32, q: *i32) -> *i32 {
    return p + q
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: pointer_arith_rules.k:24:12: error [SC067E]: the difference of two pointers is defined on raw pointers only, not '*i32' and '*i32'
// DIAG: pointer_arith_rules.k:28:12: error [SC033E]: operands '*i32' and 'unsafe *i32' do not unify
// DIAG: pointer_arith_rules.k:32:12: error [SC033E]: operands 'unsafe *i32' and 'unsafe *i64' do not unify
// DIAG: pointer_arith_rules.k:36:12: error [SC067E]: pointer arithmetic moves in units of the pointee, and 'unsafe *void' points to void
// DIAG: pointer_arith_rules.k:40:12: error [SC066E]: no operator '+' for operands '*i32' and 'f64'
// DIAG: pointer_arith_rules.k:44:12: error [SC066E]: no operator '+' for operands '*i32' and '*i32'

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid {{[0-9]+}}: {{.*}}pointer_arith_rules.k
// SEMA:       BinaryOperatorExpr {{ *}}@ 7:19 {{ *}}: *i32
// SEMA:       BinaryOperatorExpr {{ *}}@ 8:19 {{ *}}: *i32
// SEMA:       BinaryOperatorExpr {{ *}}@ 9:14 {{ *}}: *i32
// SEMA:       AssignOperatorExpr {{ *}}@ 11:5 {{ *}}: *i32
// SEMA:       AssignOperatorExpr {{ *}}@ 12:5 {{ *}}: *i32
// SEMA:       BinaryOperatorExpr {{ *}}@ 13:47 {{ *}}: bool
// SEMA:       BinaryOperatorExpr {{ *}}@ 17:25 {{ *}}: unsafe *u8
// SEMA:       BinaryOperatorExpr {{ *}}@ 18:26 {{ *}}: bool
// SEMA:       BinaryOperatorExpr {{ *}}@ 19:20 {{ *}}: isize
