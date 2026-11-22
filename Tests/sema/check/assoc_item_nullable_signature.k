// A conformer whose method returns a nullable of a different type than the
// requirement's `Self::Item?` for its own `Item` does not conform: the bound
// that needs it reports the requirement it fails.

interface Iter {
    type Item
    fn next(self) -> Self::Item?
}

class Counter impl Iter {
    type Item = i32
    var n: i32 = 0
    fn next(self) -> u64? { return null }
}

fn <T impl Iter> count(it: *T) -> i32 {
    var v = it->next()
    return 0
}

fn main() -> i32 {
    var c = Counter()
    return count(&c)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: assoc_item_nullable_signature.k:10:20: error [SC162E]: 'Counter' declares 'impl Iter' but does not conform to it: it has no 'next' with the requirement's signature
// CHECK: assoc_item_nullable_signature.k:23:12: error [SC162E]: 'Counter' does not conform to 'Iter': no member 'next' with the requirement's signature
// CHECK: assoc_item_nullable_signature.k:16:5: note [I900N]: required by this bound
// CHECK: assoc_item_nullable_signature.k:7:5: note [I900N]: 'next' is required here
