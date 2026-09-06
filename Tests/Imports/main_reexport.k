// CASE 7: re-export. main imports foo_reexport, which does
// `pub import bar::*`. That edge is PUBLIC, so bar's names are part of
// foo_reexport's surface and must be reachable through it.
//
// A re-exported name lives in foo_reexport's OVERLAY, never in its symbol
// table, and a plain `import foo_reexport` binds its ModuleDecl -- whose
// shared table IS that symbol table. So the module step consults the source
// overlay after missing in the table (MemberLookup::reexport_lookup), and
// accepts a hit only when the origin import is pub/prot. IMPORTS.md §4.4.

import foo_reexport

fn use_reexport() -> i32 {
    return foo_reexport::helper()
}
