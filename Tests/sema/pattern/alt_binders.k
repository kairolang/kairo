// Alternatives may bind a name only if every one binds it with the same type
// and the same mutability. Name resolution gives every alternative the FIRST
// alternative's binder decl, so the body sees one `x`.

enum Value { Int { x: i32 }, Big { x: i32 }, Text { x: string } }

fn shared(v: Value) -> i32 {
    return match v {
        case .Int(var x), .Big(var x) => x
// SEMA: x @ [[@LINE-1]]:42 -> var x @ [[@LINE-1]]:19
        default => 0
    }
}

fn wrong_type(v: Value) -> i32 {
    return match v {
        case .Int(var x), .Text(var x) => 0
// DIAG:      alt_binders.k:[[@LINE-1]]:33: error [SC125E]: 'x' has type '{{.*}}' here but 'i32' in an earlier alternative
// DIAG-NEXT: alt_binders.k:[[@LINE-2]]:19: note [{{[A-Z0-9]+}}]: every alternative must bind a name with the same type
        default => 0
    }
}

fn wrong_mutability(v: Value) -> i32 {
    return match v {
        case .Int(var x), .Big(const x) => 0
// DIAG:      alt_binders.k:[[@LINE-1]]:32: error [SC125E]: 'x' is bound with 'const' here but with 'var' in an earlier alternative
// DIAG-NEXT: alt_binders.k:[[@LINE-2]]:19: note [{{[A-Z0-9]+}}]: every alternative must bind a name with the same mutability
        default => 0
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
