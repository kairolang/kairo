// Derived-to-base between generic instances is decided on the instances'
// TYPES: a base list is the pattern's, read through the instance's
// arguments (MONO.md G4). `Const<i32>` of `class <T> Const derives
// Source<T>` reaches `Source<i32>` and nothing else, so the f64 instance
// stays an unrelated type -- for an implicit upcast and for `as` alike.
// In a generic body the same holds over the parameter: `*Const<U>` is a
// `*Source<U>`, not a `*Source<f64>`. The running half of this is
// Tests/Codegen/oop/generic_instance_upcast.k.

class <T> Source {
    virtual fn get(self) -> i32 { return 0 }
}

class <T> Const derives Source<T> {
    override fn get(self) -> i32 { return 1 }
}

fn <U> up(c: *Const<U>) -> *Source<U> { return c }

fn <U> wrong(c: *Const<U>) -> *Source<f64> { return c }

fn main() -> i32 {
    var k = Const<i32>()
    var ok: *Source<i32> = &k
    var no: *Source<f64> = &k
    var ca = &k as *Source<f64>
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      instance_base_substitution.k:20:53: error [SC028E]: cannot convert '*Const<U>' to '*Source<f64>'
// DIAG-NEXT: instance_base_substitution.k:25:28: error [SC028E]: cannot convert '*Const<i32>' to '*Source<f64>'
// DIAG-NEXT: instance_base_substitution.k:26:14: error [SC091E]: 'Const' and 'Source' are unrelated; use 'as unsafe *' to reinterpret
// DIAG-NOT:  error
