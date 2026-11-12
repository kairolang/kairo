import shapes::*
import iface::*
import pubhub::*
fn main() -> i32 {
    var p = Point { x: 4 }
    return p.half() + p.triple() + quad(p) + halve(p) - 32
}

// --- lit wiring -----------------------------------------------------------
// An extension travels from the file that declares it to a file that
// imports that file, and onward only through re-exports (`pub` / `prot`
// imports, a module.k's exports). Here pubhub.k re-exports ext.k with `pub import`.
// The conformance of `extend Point impl Doubled` follows the same set, so
// `quad(p)` type-checks here and the program runs.
// RUN: cd %S && %kairo %s -o %t && %t
