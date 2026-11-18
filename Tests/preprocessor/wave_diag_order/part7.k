// One of ten files that import vec and not each other. The walk reports
// the compile_error! below.
import self::vec::*

compile_error!("part7 stops here")

pub fn part7() -> i32 { return vec_len() }
