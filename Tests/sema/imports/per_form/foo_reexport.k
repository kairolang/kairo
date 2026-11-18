// foo_reexport.k  middle module for RE-EXPORT (case 7).
//   `pub import bar::*` is surface: an importer of this module SHOULD see
//   bar's names (id, Box, ...) attributed to this module's edge.
//
//   XFAIL (not yet implemented): ImportResolution currently folds only a
//   source module's OWN frozen decls, not the source's overlay entries whose
//   originating import edge is pub/prot. Until that re-export fold is added,
//   an importer of foo_reexport will NOT see bar's names. This file + its
//   main_reexport.k document the intended behavior and will pass once the
//   re-export fold lands. See RESOLUTION.md #2 "explicit re-export".

pub import bar::*

pub fn helper() -> i32 {
    return 1
}
