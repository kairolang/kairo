// both.k: the build's entry module; left, right and errs are its imports,
// so --emit-headers writes a header for each.
import left::*
import right::*
pub fn both(k: i32) -> i32 { return (try left(k) catch => 0) + (try right(k) catch => 0) }
