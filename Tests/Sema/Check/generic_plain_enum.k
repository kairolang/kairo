// A plain enum cannot be generic (enums-plain.mdx): no variant carries a
// payload for a type parameter to type. Before, it type-checked and its
// C++ was a `template` head on an `enum class`, which clang rejected in
// generated code ("enumeration cannot be a template"). A generic ADT enum
// is unaffected.
enum <T> Plain { A, B }
enum <T, U> Pair { X, Y }
enum <T> Adt { Some { v: T }, None }

fn main() -> i32 {
    var p = Plain<i32>::A
    var a = Adt<i32>::None
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:6:7: error [SC197E]: plain enum 'Plain' cannot be generic: no variant carries a payload for a type parameter to type
// DIAG-NEXT: {{.*}}:6:10: note [SC197N]: give a variant a payload to make it an ADT enum, or remove the generic parameters
// DIAG: {{.*}}:7:7: error [SC197E]: plain enum 'Pair' cannot be generic: no variant carries a payload for a type parameter to type
// DIAG-NEXT: {{.*}}:7:13: note [SC197N]: give a variant a payload to make it an ADT enum, or remove the generic parameters
