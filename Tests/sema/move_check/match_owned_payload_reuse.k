// A match that moves a payload out of a scrutinee it owns leaves that
// scrutinee moved-from: a later read of it is SC052E, with a note at the
// match. A binder over a scrutinee the match does not own (a const
// parameter, a pointer's pointee) borrows, and moving it out is a copy its
// type cannot make (SC182E), as is moving out a `const` binder.

enum <K, V> Res { Found { key: K, value: V }, Empty }

fn take(s: string) -> usize { return s.size() }
fn size_of(const r: Res<i32, string>) -> usize = match r {
    case .Found(const value) => value.size()
    default                  => 0
}

fn param_reused(r: Res<i32, string>) -> usize {
    var n: usize = match r {
        case .Found(var value) => take(value)
        default                => 0
    }

    return n + size_of(r)
}

fn local_reused() -> string {
    var r = Res<i32, string>::Found { key: 1, value: "a" }
    var s = match r {
        case .Found(var value) => value
        default                => "none"
    }

    take(s)
    return match r {
        case .Found(var value) => value
        default                => "none"
    }
}

fn in_loop(r: Res<i32, string>) -> usize {
    var n: usize = 0
    for var i = 0; i < 2; ++i {
        match r {
            case .Found(var value) { n += take(value) }
            default                { }
        }
    }

    return n
}

fn binder_reused(r: Res<i32, string>) -> usize {
    match r {
        case .Found(var value) { return take(value) + value.size() }
        default                { return 0 }
    }
}

fn const_param(const r: Res<i32, string>) -> string = match r {
    case .Found(var value) => value
    default                => "none"
}

fn through_ptr(p: *Res<i32, string>) -> string = match *p {
    case .Found(var value) => value
    default                => "none"
}

fn const_binder(r: Res<i32, string>) -> string = match r {
    case .Found(const value) => value
    default                  => "none"
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      match_owned_payload_reuse.k:21:24: error [SC052E]: 'r' is used after being moved
// CHECK-NEXT: match_owned_payload_reuse.k:16:26: note [I900N]: 'r' was moved here, by the match, whose binder 'value' takes its payload
// CHECK:      match_owned_payload_reuse.k:32:18: error [SC052E]: 'r' is used after being moved
// CHECK-NEXT: match_owned_payload_reuse.k:26:19: note [I900N]: 'r' was moved here, by the match, whose binder 'value' takes its payload
// CHECK:      match_owned_payload_reuse.k:41:15: error [SC052E]: 'r' is used after being moved
// CHECK-NEXT: match_owned_payload_reuse.k:41:15: note [I900N]: 'r' was moved here, by the match, whose binder 'value' takes its payload
// CHECK:      match_owned_payload_reuse.k:52:55: error [SC052E]: 'value' is used after being moved
// CHECK-NEXT: match_owned_payload_reuse.k:52:46: note [I900N]: 'value' was moved here, into a by-value parameter
// CHECK:      match_owned_payload_reuse.k:58:31: error [SC182E]: cannot copy a value of type 'string'
// CHECK-NEXT: match_owned_payload_reuse.k:58:31: note [I900N]: 'value' borrows its element, so the transfer out of the match cannot move it away
// CHECK:      fix-it:"{{.*}}":{58:36-58:36}:".copy()"
// CHECK-NEXT: match_owned_payload_reuse.k:58:21: note [I900N]: the binder 'value' borrows its element in place, read-only
// CHECK:      match_owned_payload_reuse.k:63:31: error [SC182E]: cannot copy a value of type 'string'
// CHECK-NEXT: match_owned_payload_reuse.k:63:31: note [I900N]: 'value' borrows its element, so the transfer out of the match cannot move it away
// CHECK:      match_owned_payload_reuse.k:68:33: error [SC182E]: cannot copy a value of type 'string'
// CHECK-NEXT: match_owned_payload_reuse.k:68:33: note [I900N]: 'value' is const, so the transfer out of the match cannot move it
