// The shapes of narrowed_cast_else_if_loop.k without the proof: a nullable
// that is not non-null on every path to a cast or a match keeps the rules of
// a nullable. A cast to another type has no conversion (SC027E) and a match
// must answer null first (SC254E).
// One diagnostic per `bad_*` function.

fn bad_else_if_or(length: i64?, chunked: bool) -> usize {
    if chunked {
        return 1
    } else if length? || length == null {
        var len = length as usize
        return len
    }

    return 0
}

fn bad_loop_no_break(d: i32?, n: i32) -> usize {
    var x: usize = 0
    var i        = 0
    while i < n {
        if !d? {
            i += 1
        }

        x = x + d as usize
        i += 1
    }

    return x
}

fn bad_loop_match_after_loop(d: i32?, n: i32) -> i32 {
    var i = 0
    while i < n {
        if !d? {
            break
        }

        i += 1
    }

    match d {
        case 0 {
            return 0
        } default {
            return 1
        }
    }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:11:19: error [SC027E]: no conversion from 'i64?' to 'usize'
// DIAG: {{.*}}:26:17: error [SC027E]: no conversion from 'i32?' to 'usize'
// DIAG: {{.*}}:43:5: error [SC254E]: a match on 'i32?' must answer null first
// DIAG-NEXT: fix-it:"{{.*}}":{44:9-44:9}:"case null { }\n        "
// END-GENERATED-CHECKS(DIAG)
