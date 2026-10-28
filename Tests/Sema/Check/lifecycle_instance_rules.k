// The lifecycle rules a generic class's declaration cannot decide -- its
// facts hang on T -- are asked of each instance a use needs, with the
// instance's own facts (ClassLifecycle::instance_failures; MONO.md G6), and
// reported at that use with the instantiation chain (D6), like an unmet
// bound: a defaulted @copy over a field the instance cannot copy (SC129E),
// a category that no longer matches the base's (SC061E), a non-trivial
// destructor over a base without a virtual one (SC056E). An instance that
// meets them (`Cell<i32>`, `Der<i32>`) is not reported, and neither is the
// generic declaration itself. Before G6 every one was silently accepted.

class Mv {
    pub var id: i32
    pub fn Mv(self, id: i32) { self.id = id; }
    @move fn Mv(self, other: Self) { self.id = other.id; }
}

class <T> Cell {
    pub var v: T
    fn Cell(self, v: T) { self.v = v; }
    @copy fn Cell(self, const other: Self) = default
}

// Reached only through two generic bodies: the error is at the root's use,
// one hop note per body that needed the next instance.
fn <T> wrap(v: T) -> i32 {
    var c: Cell<T> = Cell<T>(v)
    return 1
}

fn <T> outer(v: T) -> i32 { return wrap(v); }

fn reached() -> i32 { return outer(Mv(3)) + outer(4); }

class Base {
    pub var k: i32
    fn Base(self) { self.k = 0; }
}

class <T> Der derives Base {
    pub var v: T
    fn Der(self, v: T) { self.v = v; }
}

fn direct() -> i32 {
    var a = Der<i32>(1)
    var b = Der<Mv>(Mv(2))
    var c = Der<string>("x")
    return 0
}

fn main() -> i32 { return 0; }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG: lifecycle_instance_rules.k:32:30: error [SC129E]: 'Cell<Mv>' cannot have a defaulted copy constructor: field 'v' of type 'Mv' is move-only
// DIAG-NEXT: lifecycle_instance_rules.k:18:9: note [SC129N]: 'v' declared here
// DIAG-NEXT: lifecycle_instance_rules.k:20:11: note [I900N]: the defaulted copy constructor is declared here
// DIAG-NEXT: lifecycle_instance_rules.k:26:12: note [I900N]: in instantiation of 'Cell<Mv>' required here
// DIAG-NEXT: lifecycle_instance_rules.k:30:36: note [I900N]: in instantiation of 'wrap<Mv>' required here
// DIAG: lifecycle_instance_rules.k:46:13: error [SC061E]: 'Der<Mv>' is move-only (@move), but its base 'Base' is copyable (@copy); a derived class's lifecycle category must match its base's, or be non-transferable
// DIAG-NEXT: lifecycle_instance_rules.k:39:23: note [I900N]: 'Base' is a base of 'Der<Mv>' here
// DIAG-NEXT: lifecycle_instance_rules.k:34:1: note [I900N]: base declared here
// DIAG: lifecycle_instance_rules.k:47:13: error [SC056E]: class 'Der<string>' has a non-trivial destructor, but its base 'Base' does not have a virtual destructor; deleting a 'Der<string>' through a '*Base' would run only 'Base''s destructor and leak the rest
// DIAG-NEXT: lifecycle_instance_rules.k:39:23: note [I900N]: 'Base' is a base of 'Der<string>' here
// DIAG-NEXT: lifecycle_instance_rules.k:34:1: note [I900N]: declare 'virtual fn op delete(self)' in 'Base'
