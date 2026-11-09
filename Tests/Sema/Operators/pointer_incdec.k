// `++p` / `--p` (and the postfix forms) on a pointer are `p += 1` /
// `p -= 1` (pointers.mdx, Pointer Arithmetic), on both kinds: a safe
// pointer is allowed, staying inside its allocation is Tether's to prove,
// as for `p + 1`. A prefix one is the pointer place again; a postfix one
// is the old pointer, a value. A void pointee has no unit to move by, and
// a nullable pointer must be checked first.

fn walk(v: [i32]) -> i32 {
    var sum = 0
    for var *it = v.begin(); it != v.end(); ++it { sum += *it }
    var *e = v.end()
    --e
    var *old = e--
    return sum + *old + *(++e)
}

fn raw(p: unsafe *u8) -> unsafe *u8 {
    var unsafe *q = p
    q++
    ++q
    return q
}

fn void_step(v: *void) {
    var *w = v
    ++w
}

fn nullable_step(p: *i32?) {
    var *q? = p
    q++
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// DIAG: pointer_incdec.k:26:5: error [SC067E]: pointer arithmetic moves in units of the pointee, and '*void' points to void; cast it to a typed pointer first
// DIAG: pointer_incdec.k:31:5: error [SC265E]: 'q' may be null here; check it with 'if q?' first
// DIAG-NEXT: pointer_incdec.k:30:5: note [I900N]: 'q' is given a value that may be null here
// SEMA-LABEL: SEMA fid {{[0-9]+}}: {{.*}}pointer_incdec.k
// SEMA:       UnaryOperatorExpr {{ *}}@ 10:45 {{ *}}: *i32
// SEMA:       UnaryOperatorExpr {{ *}}@ 12:5 {{ *}}: *i32
// SEMA:       UnaryOperatorExpr {{ *}}@ 13:16 {{ *}}: *i32
// SEMA:       UnaryOperatorExpr {{ *}}@ 14:27 {{ *}}: *i32
// SEMA:       UnaryOperatorExpr {{ *}}@ 19:5 {{ *}}: unsafe *u8
// SEMA:       UnaryOperatorExpr {{ *}}@ 20:5 {{ *}}: unsafe *u8
