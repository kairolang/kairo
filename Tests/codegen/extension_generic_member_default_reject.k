// A default argument on a member of a generic extension is type-checked
// against its parameter: an integer default for a string parameter is
// SC028E, and a call that omits a parameter with no default is SC021E.
class <T> Box {
    pub var v: T
    fn Box(self, const v: T) { self.v = v }
}

extend <T> Box<T> {
    pub fn join(self, const sep: string = 5) -> string { return "a" }
    pub fn <U> pick(self, const u: U, const k: i32 = 5) -> i32 { return k }
}

fn main() -> i32 {
    var b = Box<i32>(3)
    return b.pick()
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: extension_generic_member_default_reject.k:10:43: error [SC028E]: cannot convert 'i32' to 'string'
// CHECK: extension_generic_member_default_reject.k:16:12: error [SC021E]: missing argument for parameter 'u'
