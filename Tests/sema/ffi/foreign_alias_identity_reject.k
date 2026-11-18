// The alias chain gives one identity to the json type, but only to that type:
// a different record or an integer passed where `api::Json` is expected is
// still a conversion error.
ffi "c++" import "foreign_alias_identity.h"

fn main() -> i32 {
    var j = to_json("x", 1)
    var c = api::completion()
    c.create(j)
    c.create(c)
    c.create(1)
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only -fimplicit-conv 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: foreign_alias_identity_reject.k:10:5: error [SC063E]: {{.*}}
// CHECK: foreign_alias_identity_reject.k:11:5: error [SC063E]: {{.*}}
