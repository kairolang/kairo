// One of ten files that import vec and not each other. The walk reports
// the compile_error! below.
import self::vec::*

compile_error!("part4 stops here")

pub fn part4() -> i32 { return vec_len() }
