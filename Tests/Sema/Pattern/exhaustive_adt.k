// Exhaustiveness over an ADT enum. A variant is covered only when its payload
// is: `.Some(var v)` covers `.Some`, `.Some(1)` does not, and a guarded arm
// never covers anything. The witness of a refutable payload names it.

enum Opt { Some { v: i32 }, None }

fn bound(o: Opt) -> i32 {
    match o {
// SEMA:      MatchStmt @ [[@LINE-1]]:5 [exhaustive=1 covering_arm=1 open_tail=1]
        case .Some(var v) { return v; }
// SEMA:      ConstructorPattern @ [[@LINE-1]]:14 [resolved=Variant Some]
// SEMA:      BindingPattern @ [[@LINE-2]]:20 [field=v]
        case .None        { return 0; }
    }
}

fn refutable(o: Opt) -> i32 {
    match o {
// DIAG:      exhaustive_adt.k:[[@LINE-1]]:5: error [SC120E]: match is not exhaustive: '.Some(
        case .Some(1) { return 1; }
        case .None    { return 0; }
    }
}

fn guarded(o: Opt) -> i32 {
    match o {
// DIAG:      exhaustive_adt.k:[[@LINE-1]]:5: error [SC120E]: match is not exhaustive: '.Some' is not covered
        case .Some(var v) where v > 0 { return v; }
        case .None                    { return 0; }
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
