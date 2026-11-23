// A nullable NOT proven non-null keeps the rules of a nullable in a cast and
// in a match: a cast to its `T` cannot make a value for null (SC029E), a cast
// to another type has no conversion (SC027E), and a match must answer null
// first (SC254E). A proven place whose match names null anywhere but a lone,
// unguarded first `case null` is judged by the same rules. A proven cast into
// a slot of its own type is redundant (SC031W): the read narrows there anyway.
// A match that does not answer null first proves nothing about its
// scrutinee, so a second one after it is judged on its own.
// One diagnostic per `bad_*` and `warn_*` match or cast, none per `ok_*`.

fn bad_cast_unchecked(x: i64?) -> i64 {
    var a = x as i64
    return 0
}

fn bad_cast_other(x: i32?) -> i64 {
    var a = x as i64
    return 0
}

fn bad_cast_one_path(x: i32?, c: bool) -> i64 {
    if c {
        if !x? { return 0 }
    }
    var a = x as i64
    return 0
}

fn bad_cast_null() -> i64 {
    var x: i32? = null
    var a = x as i64
    return 0
}

fn bad_cast_ptr(p: (*i32)?) -> usize {
    var a = p as usize
    return 0
}

fn bad_match_unchecked(x: i32?) -> i32 {
    match x {
        case 1 { return 1 }
        default { return 0 }
    }
}

fn bad_match_expr_unchecked(x: i32?) -> i32 {
    return match x {
        case 1 => 1
        default => 0
    }
}

fn bad_match_reassigned(x: i32?, y: i32?) -> i32 {
    var z? = x
    if !z? { return 0 }
    z = y
    match z {
        case 1 { return 1 }
        default { return 0 }
    }
}

fn bad_match_late_null(x: i32?) -> i32 {
    if !x? { return 0 }
    match x {
        case 1 { return 1 }
        case null { return 2 }
        default { return 0 }
    }
}

fn bad_match_guarded_null(x: i32?, c: bool) -> i32 {
    if !x? { return 0 }
    match x {
        case null where c { return 2 }
        default { return 0 }
    }
}

fn warn_cast_into_slot(x: i64?) -> i64 {
    if !x? { return 0 }
    return x as i64
}

fn ok_cast_proven(x: i64?) -> i64 {
    if !x? { return 0 }
    var a = x as i64
    return a
}

fn ok_match_proven(x: i32?) -> i32 {
    if !x? { return 0 }
    match x {
        case 1 { return 1 }
        default { return 0 }
    }
}

fn ok_match_proven_null(x: i32?) -> i32 {
    if !x? { return 0 }
    match x {
        case null { return 9 }
        case 1 { return 1 }
        default { return 0 }
    }
}

fn ok_match_unproven_null(x: i32?) -> i32 {
    match x {
        case null { return 9 }
        case 1 { return 1 }
        default { return 0 }
    }
}

fn bad_match_after_bad_match(x: i32?) -> i32 {
    match x {
        case 1 { }
        default { }
    }
    match x {
        case 1 { return 1 }
        default { return 0 }
    }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:12:13: error [SC029E]: cannot cast 'i64?' to 'i64'; a cast cannot fabricate a value for null
// DIAG-NEXT: {{.*}}:12:13: note [I900N]: use 'x ?? default' to supply a fallback, or 'x!' to assert non-null
// DIAG: {{.*}}:17:13: error [SC027E]: no conversion from 'i32?' to 'i64'
// DIAG: {{.*}}:25:13: error [SC027E]: no conversion from 'i32?' to 'i64'
// DIAG: {{.*}}:31:13: error [SC027E]: no conversion from 'i32?' to 'i64'
// DIAG: {{.*}}:36:13: error [SC027E]: no conversion from '*i32?' to 'usize'
// DIAG: {{.*}}:41:5: error [SC254E]: a match on 'i32?' must answer null first
// DIAG-NEXT: fix-it:"{{.*}}":{42:9-42:9}:"case null { }\n        "
// DIAG: {{.*}}:48:12: error [SC254E]: a match on 'i32?' must answer null first
// DIAG-NEXT: {{.*}}:49:9: note [I900N]: add 'case null => <value>' as the first arm
// DIAG: {{.*}}:58:5: error [SC254E]: a match on 'i32?' must answer null first
// DIAG-NEXT: fix-it:"{{.*}}":{59:9-59:9}:"case null { }\n        "
// DIAG: {{.*}}:66:5: error [SC254E]: a match on 'i32?' must answer null first
// DIAG-NEXT: {{.*}}:68:9: note [I900N]: move this arm to the top: every arm after the first matches only a value
// DIAG: {{.*}}:75:5: error [SC254E]: a match on 'i32?' must answer null first
// DIAG-NEXT: {{.*}}:76:25: note [I900N]: 'case null' takes no 'where' guard: null is answered once, by the first arm
// DIAG: {{.*}}:83:12: warning [SC031W]: redundant cast: 'i64' converts to 'i64' implicitly
// DIAG-NEXT: fix-it:"{{.*}}":{83:13-83:20}:""
// DIAG: {{.*}}:118:5: error [SC254E]: a match on 'i32?' must answer null first
// DIAG-NEXT: fix-it:"{{.*}}":{119:9-119:9}:"case null { }\n        "
// DIAG: {{.*}}:122:5: error [SC254E]: a match on 'i32?' must answer null first
// DIAG-NEXT: fix-it:"{{.*}}":{123:9-123:9}:"case null { }\n        "
// END-GENERATED-CHECKS(DIAG)
