// G14 (Compiler/Sema/NULLABLE.md 3.6): a match on `T?` answers null in its
// FIRST arm, `case null` alone and unguarded, or it is an error (SC001E):
// with a fix-it inserting the arm when there is none (statement form), a
// note at a `case null` that is out of place, guarded or in an
// alternation. A later `case null` after a first one is an error of its
// own. Narrowing: the null arm sees the place Null, every later arm
// (`default` included) NonNull; `case var v` binds the unwrapped `T`; a
// guard's true set refines its arm; after the match, the join of the arms
// that do not diverge. Exhaustiveness is over `T`: `bool?` with `case
// null`, `true`, `false` needs no `default`.

fn get() -> i32? { return null }
fn flag() -> bool? { return null }

fn narrowing(x: i32?, o: i32?) -> i32 {
    var r = 0
    match x {
        case null { r = x + 1 }
        case 0 { r = x }
        case var v where o? { r = o + v }
        default { r = x * 2 }
    }
    match x {
        case null { return 0 }
        default { }
    }
    return x + r
}

fn exhaustive() -> i32 {
    match flag() {
        case null { return 0 }
        case true { return 1 }
        case false { return 2 }
    }
}

fn errors() {
    var x? = get()
    match x {
        case 0 { }
        default { }
    }
    var e = match x { case 1 => 1 default => 2 }
    match x {
        case 0 { }
        case null { }
        default { }
    }
    match x {
        case null where true { }
        default { }
    }
    match x {
        case null, 0 { }
        default { }
    }
    match x {
        case null { }
        case 1 { }
        case null { }
        default { }
    }
    match x {
        case null { }
        case 1 { }
    }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error [
// DIAG: match_null_first.k:18:25: error [SC001E]: 'x' is always null here
// DIAG-NOT: error [
// DIAG: match_null_first.k:40:5: error [SC001E]: a match on 'i32?' must answer null first
// DIAG: fix-it:{{.*}}:{41:9-41:9}:"case null { }\n        "
// DIAG-NOT: error [
// DIAG: match_null_first.k:44:13: error [SC001E]: a match on 'i32?' must answer null first
// DIAG: note [{{.*}}]: add 'case null => <value>' as the first arm
// DIAG-NOT: error [
// DIAG: match_null_first.k:45:5: error [SC001E]: a match on 'i32?' must answer null first
// DIAG: match_null_first.k:47:9: note [{{.*}}]: move this arm to the top: every arm after the first matches only a value
// DIAG-NOT: error [
// DIAG: match_null_first.k:50:5: error [SC001E]: a match on 'i32?' must answer null first
// DIAG: match_null_first.k:51:25: note [{{.*}}]: 'case null' takes no 'where' guard: null is answered once, by the first arm
// DIAG-NOT: error [
// DIAG: match_null_first.k:54:5: error [SC001E]: a match on 'i32?' must answer null first
// DIAG: match_null_first.k:55:9: note [{{.*}}]: write 'case null' as an arm of its own: every arm after it matches only a value
// DIAG-NOT: error [
// DIAG: match_null_first.k:61:14: error [SC001E]: 'null' is answered by the first arm; this arm matches only a 'i32' value
// DIAG-NOT: error [
// DIAG: match_null_first.k:64:5: error [SC120E]: match is not exhaustive
// DIAG-NOT: error [

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA:      MatchStmt {{.*}}@ 17:5 {{.*}}null_arm=1]
// SEMA-NEXT:   decision [nodes=4 rows=3]
// SEMA-NEXT:     n3: switch $ { 0 => n0, _ => n2 }
// SEMA-NEXT:     n0: leaf arm 1
// SEMA-NEXT:     n1: leaf arm 3
// SEMA-NEXT:     n2: guard arm 2 else n1 [v=$]
// SEMA:      NamedIdentExpr {{.*}}@ 19:22 {{.*}}: i32
// SEMA:      NamedIdentExpr {{.*}}@ 20:35 {{.*}}: i32
// SEMA-NEXT: NamedIdentExpr {{.*}}@ 20:39 {{.*}}: i32
// SEMA:      NamedIdentExpr {{.*}}@ 21:23 {{.*}}: i32
// SEMA:      MatchStmt {{.*}}@ 31:5 {{.*}}[exhaustive=1 covering_arm=2 open_tail=0 null_arm=1]
// SEMA:      MatchStmt {{.*}}@ 40:5 {{.*}}[exhaustive=1 covering_arm=-1 open_tail=0]
