// CASE 7 (XFAIL): re-export. main imports foo_reexport, which does
// `pub import bar::*`. Because that edge is PUBLIC, bar's names SHOULD surface
// in main's overlay attributed to the foo_reexport edge.
//
// EXPECTED-FAIL until re-export folding is implemented: ImportResolution
// currently folds only a source's OWN frozen decls, not its pub/prot overlay
// entries. So today bar's names will be ABSENT from main's overlay and
// `foo_reexport::id` resolution through the re-export will NOT work. When the
// re-export fold lands, `id`/`Box` appear in main's overlay via foo_reexport.

import foo_reexport

fn use_reexport() -> i32 {
    return foo_reexport::helper()
}
