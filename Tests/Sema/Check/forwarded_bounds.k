// A bounds-checked parameter passed to a bounded generic must carry the
// bound itself: the caller's body is checked once, where it is defined,
// against its own bounds (generics.mdx), so `one(x)` in a `fn <T>` is the
// bound error in the caller, with a fix-it adding the bound. Before (P259)
// it type-checked and was left to the instance. The same holds for a pack
// forwarded with `args...` (functions-parameters.mdx's log_all). A bound
// that is the interface, or one deriving it, meets it; a `: type` caller
// is C++'s to check.
interface Named {
    fn op as(const self) -> string
}
interface Loud derives Named {
    fn shout(const self)
}
interface Other {
    fn z(const self)
}

fn <T impl Named> one(x: T) -> string = x as string
fn <...T impl Named> print_all(...args: T) {
    for arg in args { var s = arg as string }
}

fn <T> fwd(x: T) -> string = one(x)
fn <T impl Other> fwd_other(x: T) -> string = one(x)
fn <...T> log_all(...args: T) {
    print_all(args...)
}

fn <T impl Named> fwd_same(x: T) -> string = one(x)
fn <T impl Loud> fwd_derived(x: T) -> string = one(x)
fn <...T impl Named> log_named(...args: T) {
    print_all(args...)
}
fn <T: type> fwd_duck(x: T) -> string = one(x)

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:24:30: error [R051E]: 'one' needs 'T' to implement 'Named'
// DIAG-NEXT: fix-it:"{{.*}}forwarded_bounds.k":{24:6-24:6}:" impl Named"
// DIAG-NEXT: {{.*}}:19:5: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:24:5: note [R051N]: 'T' is declared with no bound
// DIAG: {{.*}}:25:47: error [R025E]: 'one' needs 'T' to implement 'Named'; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:19:5: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:25:5: note [I900N]: 'T' is declared here; bound it 'impl Named' too, or by an interface that derives it
// DIAG: {{.*}}:27:5: error [R051E]: 'print_all' needs 'T' to implement 'Named'
// DIAG-NEXT: fix-it:"{{.*}}forwarded_bounds.k":{26:9-26:9}:" impl Named"
// DIAG-NEXT: {{.*}}:20:8: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:26:5: note [R051N]: 'T' is declared with no bound
