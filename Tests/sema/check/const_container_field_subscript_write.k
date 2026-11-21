// An element write through a split subscript (`op []=`) on a container
// that is a field of a const object is SC071E, and the note points at the
// binding that made the object const: a const local (with the `var`
// fix-it), a const parameter, a const global, any depth of fields, and a
// pointer to const (no fix-it: the pointee's const has no keyword). What
// const does not reach stays writable: a `mutable var` field, a field of
// what a const pointer binding points to, and a `var` object.

class Inner {
    pub var items: [i32] = [1, 2]
}

class Box {
    pub var items: [i32] = [1, 2]
    pub var inn: Inner = Inner()
    pub mutable var scratch: [i32] = [0]
}

const gb = Box()

fn local_field() {
    const c = Box()
    c.items[0] = 4
    c.inn.items[1] = 5
}

fn param_field(const p: Box) {
    p.items[0] = 6
}

fn global_field() {
    gb.items[0] = 7
}

fn pointee_field(ok: *Box) {
    var pc: *const Box = ok
    pc->items[0] = 8
}

fn writable(ok: *Box) -> i32 {
    const c = Box()
    c.scratch[0] = 1
    const b: *Box = ok
    b->items[0] = 2
    var v = Box()
    v.items[0] = 3
    v.inn.items[0] = 4
    return v.items[0]
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="note ["
// CHECK: {{.*}}.k:23:5: error [SC071E]: cannot write through 'c.items[0]': its container is const, and 'op []=' takes 'self'
// CHECK-NEXT: fix-it:{{.*}}:{22:5-22:10}:"var"
// CHECK-NEXT: {{.*}}.k:22:11: note [I900N]: 'c' declared const here
// CHECK-NEXT: {{.*}}.k:24:5: error [SC071E]: cannot write through 'c.inn.items[1]': its container is const, and 'op []=' takes 'self'
// CHECK-NEXT: fix-it:{{.*}}:{22:5-22:10}:"var"
// CHECK-NEXT: {{.*}}.k:22:11: note [I900N]: 'c' declared const here
// CHECK-NEXT: {{.*}}.k:28:5: error [SC071E]: cannot write through 'p.items[0]': its container is const, and 'op []=' takes 'self'
// CHECK-NEXT: {{.*}}.k:27:22: note [I900N]: 'p' declared const here
// CHECK-NEXT: {{.*}}.k:32:5: error [SC071E]: cannot write through 'gb.items[0]': its container is const, and 'op []=' takes 'self'
// CHECK-NEXT: fix-it:{{.*}}:{19:1-19:6}:"var"
// CHECK-NEXT: {{.*}}.k:19:7: note [I900N]: 'gb' declared const here
// CHECK-NEXT: {{.*}}.k:37:5: error [SC071E]: cannot write through 'pc->items[0]': its container is const, and 'op []=' takes 'self'
// CHECK-NEXT: {{.*}}.k:36:9: note [I900N]: 'pc' declared as a pointer to const here
// CHECK-NOT: error
