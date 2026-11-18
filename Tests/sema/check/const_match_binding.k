// A `const` binding introduced by a `match` pattern cannot be assigned
// (enums-adt.mdx, Destructuring with match: "message = ... // compile error:
// message is const"). Kairo reports it, so `--type-check-only` does.
//
//
// --type-check-only rejects it as SC071E; without Sema it would pass and
// a full build fail in clang (CL001E "cannot assign to variable 'message'
// with const-qualified type").

enum <T> R {
    Ok { v: T },
    Error { message: i32 },
}

fn main() -> i32 {
    var r = R<i32>::Error { message: 3 }
    match r {
        case .Error(const message) {
            message = 4
// CHECK: const_match_binding.k:[[@LINE-1]]:13: error [SC071E]: cannot assign to 'message': it is const
        }
        case .Ok(var v) { }
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
