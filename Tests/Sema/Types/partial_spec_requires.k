// Sema/Types/partial_spec_requires.k
// A partial specialization selected by its `requires` clause (MONO.md G12):
// `struct <P> X<P> requires pred` beside a primary `X` (the v3 draft's
// NullableStorage form; its pattern is the head's own parameters, so the
// parser files it as a second primary and N reclassifies it) and `struct
// <P> X<*P> requires pred`. The registry selects a partial whose pattern
// matches AND whose clause holds at the instance's arguments; the clause is
// decided from literals and the `sizeof` / `alignof` of builtins, pointers
// and arrays of them. What it cannot decide is an error at the instance's
// first written mention, and a conformance in a selecting clause is not
// supported. Two constrained partials with one pattern are unordered (C++
// orders them by subsumption, which Kairo does not compute): ambiguous. A
// genuine second primary is still a redefinition.
pub struct <T> Store { pub var value: T }
pub struct <P> Store<P> requires sizeof P <= 8 { pub var ptr: P }
pub struct <Q> Store<Q> { pub var q: Q }           // [redef]

pub interface Named { fn name(const self) -> i32 }
pub struct <T> Conf { pub var v: T }
pub struct <P> Conf<*P> requires P impl Named { pub var p: *P }   // [conf]

pub struct Big { pub var a: i64  pub var b: i64 }
pub struct <T> Fit { pub var v: T }
pub struct <P> Fit<P> requires sizeof P <= 8 { pub var small: P }

pub struct <T> Two { pub var v: T }
pub struct <P> Two<P> requires sizeof P <= 8 { pub var a: P }
pub struct <P> Two<P> requires alignof P >= 4 { pub var b: P }

fn main() -> i32 {
    var s = Store<i32> { ptr: 1 }       // the partial: its field
    var f = Fit<Big> { v: Big { a: 1, b: 2 } }
    var t = Two<i64> { v: 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// A redefinition and the conformance refusal each stop Sema before the
// rest, so each is asked of its own copy.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=REDEF --implicit-check-not=error
// REDEF: partial_spec_requires.k:16:5: error [R029E]: redefinition of 'Store'
// RUN: sed 's|.*// \[redef\]$||' %s > %t.conf.k
// RUN: { %kairo %t.conf.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=CONF --implicit-check-not=error
// CONF: :20:5: error [SC116E]: a partial specialization selected by a conformance ('impl' / 'derives') in its 'requires' clause is not yet supported
// RUN: sed -e 's|.*// \[redef\]$||' -e 's|.*// \[conf\]$||' %s > %t.k
// RUN: { %kairo %t.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: :32:13: error [SC001E]: cannot decide whether a partial specialization of 'Fit' applies to these arguments
// DIAG-NEXT: :24:5: note [SC001N]: its 'requires' clause is decided at compile time only from literals and the 'sizeof' / 'alignof' of builtins, pointers and arrays of them
// DIAG: :33:13: error [SC001E]: ambiguous partial specializations of 'Two' for these arguments
// DIAG-NEXT: :27:5: note [SC001N]: matches this partial specialization
// DIAG-NEXT: :28:5: note [SC001N]: and this one, and neither is more specialized than the other
