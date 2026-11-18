// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// R050: an alias may not be more visible than what it names.
//
// An alias introduces a second NAME, not a second entity, so `pub type B = A`
// over a `priv A` hands importers a usable name for a type its author never
// published. The check is at the alias, once -- not at each use, which would
// be in another file and report the same mistake per caller.
//
// The interesting half is that EVERY name the target mentions counts, not just
// the outermost one. Canonicalization erases the intermediate aliases and the
// module path segments, so the check walks the SYNTACTIC target instead.

priv struct P { var x: i32 }
prot struct R { var z: i32 }
pub  struct Q { var y: i32 }

// --- the outermost name ----------------------------------------------------

pub type L1 = P
// DIAG: R050E{{.*}}pub type alias 'L1' names 'P', which is priv
// DIAG: R050N{{.*}}'P' is declared priv here

// --- through a component: each of these publishes P just as directly -------

pub type L2 = *P
// DIAG: R050E{{.*}}pub type alias 'L2' names 'P', which is priv
pub type L3 = [P]
// DIAG: R050E{{.*}}pub type alias 'L3' names 'P', which is priv
pub type L4 = (i32, P)
// DIAG: R050E{{.*}}pub type alias 'L4' names 'P', which is priv
pub type L5 = {i32: P}
// DIAG: R050E{{.*}}pub type alias 'L5' names 'P', which is priv
pub type L6 = P?
// DIAG: R050E{{.*}}pub type alias 'L6' names 'P', which is priv
pub type L7 = fn(P) -> i32
// DIAG: R050E{{.*}}pub type alias 'L7' names 'P', which is priv
pub type L8 = fn(i32) -> P
// DIAG: R050E{{.*}}pub type alias 'L8' names 'P', which is priv

// --- through a generic argument --------------------------------------------

pub class <T> Box { var v: T }

pub type L9 = Box<P>
// DIAG: R050E{{.*}}pub type alias 'L9' names 'P', which is priv

// --- through another alias: canonical would have erased the link -----------

priv type Inner = Q

pub type L10 = Inner
// DIAG: R050E{{.*}}pub type alias 'L10' names 'Inner', which is priv
// DIAG: R050N{{.*}}'Inner' is declared priv here

// --- through a path segment: a priv module leaks what it holds -------------

priv module M {
    pub struct T { var a: i32 }
}

pub type L11 = M::T
// DIAG: R050E{{.*}}pub type alias 'L11' names 'M', which is priv

// --- narrowing is measured, not just pub-vs-priv ---------------------------

pub type L12 = R
// DIAG: R050E{{.*}}pub type alias 'L12' names 'R', which is prot
prot type L13 = P
// DIAG: R050E{{.*}}prot type alias 'L13' names 'P', which is priv

// --- and these are all legal -----------------------------------------------
//
// The last one is the reason an unwritten visibility ranks as the WIDEST it
// could be rather than resolving the member defaults here: a false positive
// rejects a legal program, and the defaults belong to AccessCheck, not to T.

pub  type OK1 = Q
priv type OK2 = P
priv type OK3 = R
prot type OK4 = R
type      OK5 = Q
pub  type OK6 = Box<Q>

// DIAG-NOT: OK{{[0-9]}}
