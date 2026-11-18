// PatternCompilation's decision trees as --print-sema shows them: one row
// per node under the match's row, root first. Nodes are numbered in build
// order (children before parents), so the root has the highest number.

enum Direction { North, East, South, West }

fn dir(d: Direction) -> i32 {
    return match d {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=3 open_tail=1]
// SEMA-NEXT: decision [nodes=5 rows=4]
// SEMA-NEXT: n4: switch $ { .North => n0, .East => n1, .South => n2, .West => n3, _ => unmatched }
// SEMA-NEXT: n0: leaf arm 0
// SEMA-NEXT: n1: leaf arm 1
// SEMA-NEXT: n2: leaf arm 2
// SEMA-NEXT: n3: leaf arm 3
        case .North => 1
        case .East  => 2
        case .South => 3
        case .West  => 4
    }
}

// Alternatives of one arm merge into one range edge; `..` excludes its end.
fn status(code: i32) -> i32 {
    return match code {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=4 open_tail=0]
// SEMA-NEXT: decision [nodes=6 rows=5]
// SEMA-NEXT: n5: switch $ { 1..=3 => n0, 200 => n1, 300..=399 => n2, 400..=499 => n3, _ => n4 }
// SEMA-NEXT: n0: leaf arm 1
// SEMA-NEXT: n1: leaf arm 0
// SEMA-NEXT: n2: leaf arm 2
// SEMA-NEXT: n3: leaf arm 3
// SEMA-NEXT: n4: leaf arm 4
        case 200       => 1
        case 1, 2, 3   => 2
        case 300..400  => 3
        case 400..=499 => 4
        default        => 0
    }
}

// A tuple literal: one column per element, each tested at most once on a path.
fn pair(a: i32, b: i32) -> i32 {
    return match (a, b) {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=3 open_tail=0]
// SEMA-NEXT: decision [nodes=7 rows=4]
// SEMA-NEXT: n6: switch $.0 { 0 => n2, _ => n5 }
// SEMA-NEXT: n0: leaf arm 0
// SEMA-NEXT: n1: leaf arm 1 [y=$.1]
// SEMA-NEXT: n2: switch $.1 { 0 => n0, _ => n1 }
// SEMA-NEXT: n3: leaf arm 2 [x=$.0]
// SEMA-NEXT: n4: leaf arm 3
// SEMA-NEXT: n5: switch $.1 { 0 => n3, _ => n4 }
        case (0, 0)     => 1
        case (0, var y) => 10 + y
        case (var x, 0) => 20 + x
        default         => 99
    }
}

// A guard is a leaf whose failure continues with the rows below it.
fn guarded(x: i32, c: bool) -> i32 {
    return match x {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=2 open_tail=0]
// SEMA-NEXT: decision [nodes=4 rows=3]
// SEMA-NEXT: n3: switch $ { 1 => n1, _ => n2 }
// SEMA-NEXT: n0: leaf arm 1
// SEMA-NEXT: n1: guard arm 0 else n0
// SEMA-NEXT: n2: leaf arm 2
        case 1 where c => 10
        case 1         => 11
        default        => 0
    }
}

fn word(s: string) -> i32 {
    return match s {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=3 open_tail=0]
// SEMA-NEXT: decision [nodes=5 rows=4]
// SEMA-NEXT: n4: switch $ { "a" => n0, "abc" => n1, "xyz" => n2, _ => n3 }
        case "a"   => 1
        case "abc" => 2
        case "xyz" => 3
        default    => 0
    }
}

fn flag(b: bool) -> i32 {
    return match b {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=1 open_tail=0]
// SEMA-NEXT: decision [nodes=3 rows=2]
// SEMA-NEXT: n2: switch $ { true => n0, false => n1 }
// SEMA-NEXT: n0: leaf arm 0
// SEMA-NEXT: n1: leaf arm 1
        case true  => 7
        case false => 3
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG-NOT: error
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
