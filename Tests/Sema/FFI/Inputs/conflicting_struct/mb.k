ffi "c" import "hb.h"
pub fn fb() -> f64 { var p: Pt; p.y = 2.0; return pt_get(p) }
