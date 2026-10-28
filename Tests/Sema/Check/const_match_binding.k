// A `const` binding introduced by a `match` pattern cannot be assigned
// (enums-adt.mdx, Destructuring with match: "message = ... // compile error:
// message is const"). Kairo reports it, so `--type-check-only` does.
//
// XFAIL: *
// Ticket "[Sema] Assigning to a `const` match-pattern binding is not
// diagnosed by Sema" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today
// --type-check-only accepts it and a full build fails in clang (CL001E
// "cannot assign to variable 'message' with const-qualified type"). The code
// is not decided; the check asks for an error at the marked line. When it
// XPASSes, delete the XFAIL and pin the code and message.

enum <T> R {
    Ok { v: T },
    Error { message: i32 },
}

fn main() -> i32 {
    var r = R<i32>::Error { message: 3 }
    match r {
        case .Error(const message) {
            message = 4
// CHECK: const_match_binding.k:[[@LINE-1]]:{{[0-9]+}}: error [{{[A-Z]+[0-9]+}}E]:
        }
        case .Ok(var v) { }
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
