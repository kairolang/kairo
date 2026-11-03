// Corpus for main.k: imports surface PRIVATELY, so nothing it gets from
// surface -- surface's own names or what surface re-exports -- is mid's
// surface.
import surface::*

pub fn mid_value() -> i32 { return surface_value() + deep_value() }
