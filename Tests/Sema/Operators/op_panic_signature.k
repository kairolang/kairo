// `op panic` is optional, and when a type defines it, it is exactly
// `fn op panic (const self) -> string` (PANIC.md §1.5): the display path
// reads the message from a const caught error and through a C++ `const&`.
// A non-const receiver is an error whose edit inserts `const`; a result
// that is not `string` is an error whose edit writes `string`. In a type's
// body and in an extension alike.

class Good {
    var key: string
    fn op panic (const self) -> string { return self.key }
}

class MutableSelf {
    var n: i32
    fn op panic (self) -> string { return "m" }
}

class WrongResult {
    var n: i32
    fn op panic (const self) -> i32 { return self.n }
}

class NoResult {
    var n: i32
    fn op panic (const self) { }
}

struct Plain { var n: i32 }

extend Plain {
    fn op panic (self) -> string { return "plain" }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: op_panic_signature.k:15:18: error [SC001E]: 'op panic' takes 'const self': the message is read from a const caught error
// CHECK-NEXT: fix-it:"{{.*}}op_panic_signature.k":{15:18-15:18}:"const "
// CHECK-NEXT: op_panic_signature.k:15:5: note [SC001N]: the operator is declared here
// CHECK: op_panic_signature.k:20:33: error [SC001E]: 'op panic' must return 'string', the error's message
// CHECK-NEXT: fix-it:"{{.*}}op_panic_signature.k":{20:33-20:36}:"string"
// CHECK-NEXT: op_panic_signature.k:20:5: note [SC001N]: the operator is declared here
// CHECK: op_panic_signature.k:25:5: error [SC001E]: 'op panic' must return 'string', the error's message
// CHECK-NEXT: fix-it:"{{.*}}op_panic_signature.k":{25:29-25:29}:" -> string"
// CHECK-NEXT: op_panic_signature.k:25:5: note [SC001N]: the operator is declared here
// CHECK: op_panic_signature.k:31:18: error [SC001E]: 'op panic' takes 'const self': the message is read from a const caught error
// CHECK-NEXT: fix-it:"{{.*}}op_panic_signature.k":{31:18-31:18}:"const "
// CHECK-NEXT: op_panic_signature.k:31:5: note [SC001N]: the operator is declared here
