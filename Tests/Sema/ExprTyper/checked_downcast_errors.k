// G18 (casting.md, Downcasting): what the checked downcast `p as (*D)?`
// refuses. A base with no virtual method has no runtime type to check
// (SC025E, note at the base), `as static` never downcasts (SC024E), and
// unrelated classes are no downcast at all (SC091E). Accepted: a
// polymorphic base, and a generic pointee (checked per instance in C++).

class Plain { pub var x: i32 = 0 }
class Below derives Plain { }
class Animal { virtual fn kind(self) -> i32 { return 0 } }
class Dog derives Animal { }
class Rock { virtual fn mass(self) -> i32 { return 1 } }

fn <T> pick(a: *Animal, like: *T) -> (*T)? { return a as (*T)? }

fn main() -> i32 {
    var b = Below()
    var p: *Plain = &b
    var d = Dog()
    var a: *Animal = &d
    var *e1? = p as (*Below)?
    var *e2? = a as static (*Dog)?
    var *e3? = a as (*Rock)?
    var *ok1? = a as (*Dog)?
    var *ok2? = pick(a, &d)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error [
// DIAG: checked_downcast_errors.k:20:16: error [SC025E]: cannot downcast from '*Plain': 'Plain' has no virtual methods, so there is no runtime type to check
// DIAG-NEXT: checked_downcast_errors.k:7:1: note
// DIAG-NOT: error [
// DIAG: checked_downcast_errors.k:21:16: error [SC024E]: static downcast from '*Animal' to '*Dog?' is not allowed
// DIAG-NOT: error [
// DIAG: checked_downcast_errors.k:22:16: error [SC091E]: 'Animal' and 'Rock' are unrelated; use 'as unsafe *' to reinterpret
// DIAG-NOT: error [
