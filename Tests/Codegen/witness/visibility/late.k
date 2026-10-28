// witness/visibility/late.k -- a row is a program-wide fact, but a TU may
// only USE one whose implementing extension it (transitively) imports
// (MONO.md D7; RESOLUTION.md §2b, Visibility). sees.k imports ea.k, whose
// `extend Metric impl Scalable` makes `twice<Metric>` conform there; blind.k
// imports neither ea.k nor anything that does, and calls the same
// `twice<Metric>`. The c1-c3 chain only orders the TUs so that blind.k is
// checked AFTER sees.k: the row and the live instance already exist when
// blind.k meets them. Before D7 blind.k reused both and was silently
// accepted; now it is checked against what it can see, and the note names
// the extension it does not import.
//
// ea.k / ec.k extend Metric impl Scalable in a file that is neither
// Metric's nor Scalable's, which the orphan rule forbids once it is built
// (RESOLUTION.md ExtensionOrphanCheck; not diagnosed yet). Under that rule
// any TU that can name both Metric and Scalable imports both files, so it
// sees every legal extension: this case needs the orphan-violating layout,
// and becomes the orphan error when that check lands.
import c1
import c2
import c3
import sees
import blind
fn main() -> i32 { return sees::use_a() + blind::use_b() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG:      blind.k:6:12: error [SC001E]: 'Metric' does not conform to 'Scalable' here: 'scale' is implemented by an extension this file does not import
// DIAG-NEXT: iface.k:7:9: note [I900N]: required by this bound
// DIAG-NEXT: iface.k:2:5: note [I900N]: 'scale' is required here
// DIAG-NEXT: ea.k:4:9: note [I900N]: this extension member implements it, in a file this one does not import; import its module here to use the conformance
