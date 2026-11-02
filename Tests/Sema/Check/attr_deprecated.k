// `@deprecated` warns at every use of the declaration, not at the
// declaration, naming it and its message, with a note at the attribute.
// A use inside the deprecated declaration itself is not reported.

@deprecated("use new_fn instead")
fn old_fn() -> i32 { return old_fn_helper() }

fn old_fn_helper() -> i32 { return 1 }

@deprecated
struct OldS { var a: i32 }

class C {
    @deprecated("read v directly")
    fn get(const self) -> i32 { return self.v }
    var v: i32 = 0
}

@deprecated("gone in 2.0") var old_g: i32 = 3

fn user(c: *C) -> i32 {
    var s = OldS{ a: 1 }
    var p: *OldS = &s
    return old_fn() + c->get() + old_g + p->a
}

fn local_use() -> i32 {
    @deprecated("a local") var lv: i32 = 2
    return lv
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK-DAG: attr_deprecated.k:22:13: warning [SC001W]: 'OldS' is deprecated
// CHECK-DAG: attr_deprecated.k:23:13: warning [SC001W]: 'OldS' is deprecated
// CHECK-DAG: attr_deprecated.k:24:12: warning [SC001W]: 'old_fn' is deprecated: use new_fn instead
// CHECK-DAG: attr_deprecated.k:24:{{[0-9]+}}: warning [SC001W]: 'get' is deprecated: read v directly
// CHECK-DAG: attr_deprecated.k:24:{{[0-9]+}}: warning [SC001W]: 'old_g' is deprecated: gone in 2.0
// CHECK-DAG: attr_deprecated.k:29:12: warning [SC001W]: 'lv' is deprecated: a local
// CHECK-DAG: attr_deprecated.k:5:1: note [{{[A-Z0-9]+}}]: 'old_fn' was marked deprecated here
