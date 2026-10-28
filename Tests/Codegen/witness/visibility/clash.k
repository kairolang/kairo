// witness/visibility/clash.k -- two files each declare `extend Metric impl
// Scalable` with a different `scale` (ea.k and ec.k), and each is imported
// by one TU (sees.k, other.k). One conformance cannot have two
// implementations: every TU's C++ carries the one witness specialization
// `Scalable_witness<Metric>` (ODR), so the second TU to check its use is an
// error naming both. Before D7 it silently reused the first TU's row, and
// so called the other file's `scale`.
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
import other
fn main() -> i32 { return sees::use_a() + other::use_c() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
// DIAG:      sees.k:6:12: error [SC001E]: 'Metric' conforms to 'Scalable' through a different implementation here than elsewhere in the program; a conformance has one implementation
// DIAG-NEXT: iface.k:7:9: note [I900N]: required by this bound
// DIAG-NEXT: ea.k:4:9: note [I900N]: this implementation is the one visible here
// DIAG-NEXT: ec.k:4:9: note [I900N]: this one implements it for another file of the program
