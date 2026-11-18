import shapes::*
import iface::*
import plainhub::*
fn main() -> i32 {
    var p = Point { x: 4 }
    return p.half() + p.triple() + quad(p) + halve(p) - 32
}

// --- lit wiring -----------------------------------------------------------
// An extension travels from the file that declares it to a file that
// imports that file, and onward only through re-exports (`pub` / `prot`
// imports, a module.k's exports). Here plainhub.k imports ext.k with a plain `import`, which is `priv`,
// so ext.k's `triple` is not visible here, and neither is the conformance
// of `extend Point impl Doubled`: `quad(p)` cannot use it. shapes.k's own
// `half` travels with Point and stays visible. An import edge does not carry
// every extension.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      via_plain_import.k:6:25: error [R025E]: no member named 'triple' in 'Point'
// CHECK:      ext.k:4:1: note [I900N]: an extension of 'Point' in 'ext.k' declares 'triple'; import it to use it
// CHECK:      via_plain_import.k:6:36: error [SC162E]: 'Point' does not conform to 'Doubled' here: 'twice' is implemented by an extension this file does not import
// CHECK:      ext.k:3:33: note [I900N]: this extension member implements it, in a file this one does not import
