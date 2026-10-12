// Payload subpatterns: names first, then positions. A binder takes the field
// of its own name; any other subpattern takes the field at its position. A
// field reached twice is an error; fields left out are not tested.

enum Dir  { North, South }
enum Pair { Found { key: i32, value: i32 }, Missing }
enum <K, V> LookupResult { Found { key: K, value: V }, NotFound { key: K } }

fn takes_string(s: string) { }

fn no_payload(d: Dir) {
    match d {
        case .North(var x) { }
// DIAG: payload_err.k:[[@LINE-1]]:14: error [SC124E]: 'North' carries no payload
        default { }
    }
}

fn no_such_field(p: Pair) {
    match p {
        case .Found(var vlaue) { }
// DIAG: payload_err.k:[[@LINE-1]]:21: error [SC124E]: 'Found' has no field named 'vlaue'; a binder takes the field of its own name
        default { }
    }
}

fn too_many(p: Pair) {
    match p {
        case .Found(1, 2, 3) { }
// DIAG: payload_err.k:[[@LINE-1]]:27: error [SC124E]: 'Found' has 2 field(s); this is subpattern 3
        default { }
    }
}

fn twice(p: Pair) {
    match p {
        case .Found(0..=9, var key) { }
// DIAG:      payload_err.k:[[@LINE-1]]:28: error [SC124E]: field 'key' of 'Found' is matched twice
// DIAG-NEXT: payload_err.k:[[@LINE-2]]:28: note [{{[A-Z0-9]+}}]: a binder takes the field of its own name; any other subpattern takes the field at its position
        default { }
    }
}

// `0..=9` takes `key` (position 0), `var value` takes `value` (its name):
// `value` is a string, so it can be passed where only a string fits.
fn mixed(r: LookupResult<i32, string>) {
    match r {
        case .Found(0..=9, var value) { takes_string(value) }
// SEMA: RangePattern @ [[@LINE-1]]:21 [field=key]
// SEMA: BindingPattern @ [[@LINE-2]]:28 [field=value]
        default { }
    }
}

// Generic payloads are seen through the instance.
fn generic(r: LookupResult<string, i32>) -> i32 {
    match r {
        case .Found(var key, var value) {
            takes_string(key)
            var n: i32 = value
            return n
        }
        case .NotFound(var key) { takes_string(key) }
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
