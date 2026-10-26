// G15 (Compiler/Sema/NULLABLE.md §4, 4.1, 4.2): reading the VALUE of a
// nullable place the analysis has not proven non-null is an error, in
// every mode, at the read, with a note saying what made it so:
//   SC001E "'x' may be null here; check it with 'if x?' first"
//   SC001E "'x' is always null here"
// It replaces the type errors these reads used to get (SC066E / SC067E
// "no operator for 'i32?'", SC070E "cannot dereference nullable", R027E
// "'->' requires a pointer", R025E "no member in 'T?'", SC028E "cannot
// convert 'i32?' to 'i32'", SC063E "no matching overload") and is reported
// ONCE: nothing cascades from it. Covered: an unchecked parameter through
// every consumer (operators, `-`, `*`, `->`, `.`, a method, `+=` both
// ways, a call taking `T`, an initializer, `return`, a subscript, a
// `bool?` condition); Null after `= null`, after `var x: T?`, and on the
// failing side of a test; Maybe after a join; a global after a call; a
// place the loop assigns, at the loop's head; a closure capturing a
// nullable (Maybe inside, whatever was checked outside); a local written
// through a pointer to it (G12); a field path. The 4.1 precedence trap gets the
// parenthesizing fix-it, and none when another place in it is unproven.
// A nullable that is no place (`mk().v`) keeps R025E.

class Foo { pub var v: i32 = 1; pub fn get(self) -> i32 { return self.v } }
struct S { pub var cache: Foo? = null }

var g: i32? = 4

fn mk() -> Foo? { return Foo() }
fn mkn() -> i32? { return 2 }
fn take(x: i32) -> i32 { return x }
fn noop() { }

fn consumers(a: i32?, p: (*Foo)?, f: Foo?, xs: [i32]?, b: bool?) -> i32 {
    var r = 0
    var e1 = a + 1
    var e2 = -a
    var e3 = *p
    var e4 = p->v
    var e5 = f.v
    var e6 = f.get()
    r += a
    a += 1
    take(a)
    var e7: i32 = a
    var e8 = xs[0]
    if b { r += 1 }
    return a
}

fn states(c: bool) -> i32 {
    var y: i32? = 5
    y = null
    var e1 = y + 1
    var d: i32?
    var e2 = d + 1
    var j: i32? = 1
    if c { j = mkn() }
    var e4 = j + 1
    var j2: i32? = 1
    if c { j2 = null }
    var e3 = j2 + 1
    return 0
}

fn failing(a: i32?) -> i32 {
    if a? { return 1 } else { return a }
}

fn globals() -> i32 {
    if g? { noop(); return g }
    return 0
}

fn loops() -> i32 {
    var x: i32? = 1
    var r = 0
    while r < 3 {
        r += x
        x = null
    }
    return r
}

fn closures(a: i32?) -> i32 {
    if a? {
        var f = fn () -> i32 { return a };
        return f()
    }
    return 0
}

fn addressed() -> i32 {
    var x: i32? = 3
    var p = &x
    if x? { *p = null; return x }
    return 0
}

fn paths(o: S) -> i32 {
    return o.cache.v
}

fn trap(a: i32?) -> bool { return a? && a > 0 || a < 0 }
fn trap_other(a: i32?, b: i32?) -> bool { return a? && a > 0 || b < 0 }

fn not_a_place() -> i32 { return mk().v }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:33:14: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: access_errors.k:31:14: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:34:15: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: access_errors.k:31:14: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:35:15: error [SC001E]: 'p' may be null here; check it with 'if p?' first
// DIAG-NEXT: access_errors.k:31:23: note [{{.*}}]: 'p' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:36:14: error [SC001E]: 'p' may be null here; check it with 'if p?' first
// DIAG-NEXT: access_errors.k:31:23: note [{{.*}}]: 'p' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:37:14: error [SC001E]: 'f' may be null here; check it with 'if f?' first
// DIAG-NEXT: access_errors.k:31:35: note [{{.*}}]: 'f' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:38:14: error [SC001E]: 'f' may be null here; check it with 'if f?' first
// DIAG-NEXT: access_errors.k:31:35: note [{{.*}}]: 'f' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:39:10: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: access_errors.k:31:14: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:40:5: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: access_errors.k:31:14: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:41:10: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: access_errors.k:31:14: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:42:19: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: access_errors.k:31:14: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:43:14: error [SC001E]: 'xs' may be null here; check it with 'if xs?' first
// DIAG-NEXT: access_errors.k:31:44: note [{{.*}}]: 'xs' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:44:8: error [SC001E]: 'b' may be null here; check it with 'if b?' first
// DIAG-NEXT: access_errors.k:31:56: note [{{.*}}]: 'b' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:45:12: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: access_errors.k:31:14: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:51:14: error [SC001E]: 'y' is always null here
// DIAG-NEXT: access_errors.k:50:5: note [{{.*}}]: 'y' is set to null here
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:53:14: error [SC001E]: 'd' is always null here
// DIAG-NEXT: access_errors.k:52:5: note [{{.*}}]: 'd' is set to null here
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:56:14: error [SC001E]: 'j' may be null here; check it with 'if j?' first
// DIAG-NEXT: access_errors.k:55:12: note [{{.*}}]: 'j' is given a value that may be null here
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:59:14: error [SC001E]: 'j2' may be null here; check it with 'if j2?' first
// DIAG-NEXT: access_errors.k:57:5: note [{{.*}}]: 'j2' is declared nullable here
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:64:38: error [SC001E]: 'a' is always null here
// DIAG-NEXT: access_errors.k:64:8: note [{{.*}}]: on this path, the test here found 'a' null
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:68:28: error [SC001E]: 'g' may be null here; check it with 'if g?' first
// DIAG-NEXT: access_errors.k:68:13: note [{{.*}}]: 'g' is global: this call may change it, which ends the check before it
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:76:14: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: access_errors.k:77:9: note [{{.*}}]: 'x' may be changed in the loop here, so it may be null at the top of the loop
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:84:39: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: access_errors.k:82:13: note [{{.*}}]: 'a' is captured by the closure; inside it, no check from outside holds, since the closure may run anywhere
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:93:31: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: access_errors.k:92:13: note [{{.*}}]: a pointer to 'x' is taken here; any call after it, or a write through it, may change 'x'
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:98:12: error [SC001E]: 'o.cache' may be null here; check it with 'if o.cache?' first
// DIAG-NEXT: access_errors.k:22:16: note [{{.*}}]: 'cache' is declared nullable here
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:101:50: error [SC001E]: 'a' may be null here; check it with 'if a?' first
// DIAG-NEXT: fix-it:{{.*}}:{101:41-101:41}:"("
// DIAG-NEXT: fix-it:{{.*}}:{101:55-101:55}:")"
// DIAG-NEXT: access_errors.k:101:9: note [{{.*}}]: 'a' is a nullable parameter; it may be null on entry
// DIAG-NEXT: note [{{.*}}]: '&&' binds tighter than '||': the right of '||' runs when 'a?' may have failed; parenthesize, or force it with 'unwrap!(a)'
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:102:65: error [SC001E]: 'b' may be null here; check it with 'if b?' first
// DIAG-NEXT: access_errors.k:102:24: note [{{.*}}]: 'b' is a nullable parameter; it may be null on entry
// DIAG-NOT: {{error|warning}}
// DIAG: access_errors.k:104:39: error [R025E]: no member named 'v' in 'Foo?'
// DIAG-NOT: {{error|warning}}
