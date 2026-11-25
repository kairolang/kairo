// A pack forwarded with `args...` into an overload set is checked at the
// definition, as into one function (forwarded_bounds.k): when every
// candidate bounds its type pack by an interface the forwarded pack does
// not promise, no instance can call any of them, and the caller's body is
// the error. A set with one candidate that may take the expansion (a bound
// met, a pack with no bound, a function without a pack) is the instance's
// to pick from, and type-checks.
interface Named {
    fn op as(const self) -> string
}
interface Loud derives Named {
    fn shout(const self)
}
interface Other {
    fn z(const self)
}

fn <...T impl Named> show(...args: T) {
    for arg in args { var s = arg as string }
}
fn <...T impl Named> show(tag: i32, ...args: T) {
    for arg in args { var s = arg as string }
}

fn <...T impl Named> mixed(...args: T) {
    for arg in args { var s = arg as string }
}
fn <...T impl Loud> mixed(tag: i32, ...args: T) {
    for arg in args { arg.shout() }
}

fn <...T impl Named> open_too(...args: T) {
    for arg in args { var s = arg as string }
}
fn <...T> open_too(tag: i32, ...args: T) {}

fn <...T impl Named> plain_too(...args: T) {
    for arg in args { var s = arg as string }
}
fn plain_too(a: i32) {}

fn <...T> log_all(...args: T) {
    show(args...)
}
fn <...T impl Other> log_other(...args: T) {
    show(args...)
}
fn <...T> log_mixed(...args: T) {
    mixed(args...)
}

fn <...T impl Named> log_named(...args: T) {
    show(args...)
}
fn <...T impl Loud> log_loud(...args: T) {
    show(args...)
    mixed(args...)
}
fn <...T> log_open(...args: T) {
    open_too(args...)
}
fn <...T> log_plain(...args: T) {
    plain_too(args...)
}
fn <...T: type> log_duck(...args: T) {
    show(args...)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -fduck-generics %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:43:5: error [R051E]: 'show' needs 'T' to implement 'Named'
// DIAG-NEXT: fix-it:"{{.*}}forwarded_pack_overloads.k":{42:9-42:9}:" impl Named"
// DIAG-NEXT: {{.*}}:18:8: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:21:8: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:42:5: note [R051N]: 'T' is declared with no bound
// DIAG: {{.*}}:46:5: error [R025E]: 'show' needs 'T' to implement 'Named'; none of the bounds of 'T' does
// DIAG-NEXT: {{.*}}:18:8: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:21:8: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:45:5: note [I900N]: 'T' is declared here; bound it 'impl Named' too, or by an interface that derives it
// DIAG: {{.*}}:49:5: error [R051E]: 'mixed' needs 'T' to implement 'Named'
// DIAG-NEXT: {{.*}}:25:8: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:28:8: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:48:5: note [R051N]: 'T' is declared with no bound
