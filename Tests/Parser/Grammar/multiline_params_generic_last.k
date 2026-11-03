// P354: a parameter list split over lines whose last parameter's type ends
// in a generic `>`, with no trailing comma. The `>` was consumed keeping the
// newline after it, inside the list's own suppression, so the list saw a
// newline where `)` was expected: S047E "expected ')' to close the parameter
// list". A trailing comma, or a last type not ending in `>`, parsed. Sites:
// Resolution/ImportProbe.k, AST/Printer/ASTPrinter.k,
// Preprocessor/Preprocessor.k, Parser/DeclParse.k.

struct <T> Box { var v: T }

fn first(
    seen: Box<u8>
) -> u8 {
    return seen.v
}

fn nested(
    a: i32,
    rows: Box<Box<u8>>
) -> i32 {
    return a
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)
