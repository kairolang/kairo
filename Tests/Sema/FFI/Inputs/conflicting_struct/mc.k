ffi "c" import "hc.h"
pub fn fc() -> i32 { var p: Pt; p.x = 4; return pt_get(p) }
