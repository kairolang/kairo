// A match whose every head is a constant or a wildcard -- the shape of a
// generated table such as the diagnostic registry -- is checked with one set
// and compiled with one bucketing pass. The verdicts must be the
// general matrix's: a repeated constant is dead, a default after every
// constructor is dead, a missing constructor is the witness, and the trees
// keep their edge order and merges.

enum Sev { Note, Warn, Err, Fatal }

fn twice(s: Sev) -> i32 {
    return match s {
        case Sev::Note => 0
        case Sev::Warn => 1
        case Sev::Note => 2
// DIAG: constant_table.k:[[@LINE-1]]:9: error [SC121E]: this arm can never match: the arms before it already cover every value it matches
        case Sev::Err  => 3
        case Sev::Fatal => 4
    }
}

fn missing(s: Sev) -> i32 {
    return match s {
// DIAG: constant_table.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '.Err' is not covered
        case Sev::Note => 0
        case Sev::Warn, Sev::Fatal => 1
    }
}

fn default_after_all(s: Sev) -> i32 {
    return match s {
        case Sev::Note  => 0
        case Sev::Warn  => 1
        case Sev::Err   => 2
        case Sev::Fatal => 3
        default         => 4
// DIAG: constant_table.k:[[@LINE-1]]:9: error [SC121E]: this arm can never match: the arms before it already cover every value it matches
    }
}

// A guarded arm covers nothing; the unguarded repeat is live.
fn guarded(s: Sev, c: bool) -> i32 {
    return match s {
        case Sev::Note where c => 0
        case Sev::Note         => 1
        default                => 2
    }
}

fn dup_alt(n: i32) -> i32 {
    return match n {
        case 1, 2, 1 => 1
// DIAG: constant_table.k:[[@LINE-1]]:20: error [SC122E]: this alternative can never match: earlier patterns already cover every value it matches
        default => 0
    }
}

fn int_hole(n: u8) -> i32 {
    return match n {
// DIAG: constant_table.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: '2..=255' is not covered
        case 0 => 0
        case 1 => 1
    }
}

fn bool_missing(b: bool) -> i32 {
    return match b {
// DIAG: constant_table.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: 'false' is not covered
        case true => 1
    }
}

fn str_dup(s: string) -> i32 {
    return match s {
        case "a" => 1
        case "b" => 2
        case "a" => 3
// DIAG: constant_table.k:[[@LINE-1]]:9: error [SC121E]: this arm can never match: the arms before it already cover every value it matches
        default  => 0
    }
}

fn str_no_default(s: string) -> i32 {
    return match s {
// DIAG: constant_table.k:[[@LINE-1]]:12: error [SC120E]: match is not exhaustive: 'string' values other than the ones listed are not covered
        case "a" => 1
    }
}

// Points merge across adjacent keys of one arm and split at a gap; a
// wildcard row joins every edge.
fn points(n: i32) -> i32 {
    return match n {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=3 open_tail=0]
// SEMA-NEXT: decision [nodes=5 rows=4]
// SEMA-NEXT: n4: switch $ { 1..=3 => n0, 5 => n1, 7 => n2, _ => n3 }
// SEMA-NEXT: n0: leaf arm 1
// SEMA-NEXT: n1: leaf arm 2
// SEMA-NEXT: n2: leaf arm 0
// SEMA-NEXT: n3: leaf arm 3
        case 7       => 0
        case 3, 1, 2 => 1
        case 5       => 2
        default      => 9
    }
}

fn strings(s: string, c: bool) -> i32 {
    return match s {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=3 open_tail=0]
// SEMA-NEXT: decision [nodes=6 rows=4]
// SEMA-NEXT: n5: switch $ { "b" => n0, "a" => n2, _ => n4 }
// SEMA-NEXT: n0: leaf arm 0
// SEMA-NEXT: n1: leaf arm 2
// SEMA-NEXT: n2: guard arm 1 else n1
// SEMA-NEXT: n3: leaf arm 3
// SEMA-NEXT: n4: guard arm 1 else n3
        case "b"       => 1
        case _ where c => 2
        case "a"       => 3
        default        => 0
    }
}

fn nested(s: Sev, n: i32) -> i32 {
    return match s {
// SEMA:      MatchExpr @ [[@LINE-1]]:12 : i32 [exhaustive=1 covering_arm=1 open_tail=0]
// SEMA-NEXT: decision [nodes=3 rows=2]
// SEMA-NEXT: n2: switch $ { .Note => n0, _ => n1 }
        case Sev::Note => match n {
// SEMA:      MatchExpr @ [[@LINE-1]]:27 : i32 [exhaustive=1 covering_arm=2 open_tail=0]
// SEMA-NEXT: decision [nodes=4 rows=3]
// SEMA-NEXT: n3: switch $ { 1 => n0, 2 => n1, _ => n2 }
            case 1  => 1
            case 2  => 2
            default => 0
        }
        default => 9
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
