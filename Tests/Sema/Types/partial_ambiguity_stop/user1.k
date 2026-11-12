// One of eight files that import pair and not each other. The written
// Pair<i32, i32> is the ambiguity T reports once per build; the body's
// mismatch is a typed-check error, reported unless T stopped this file.
import self::pair::*

pub fn use1(p: Pair<i32, i32>) -> i32 {
    var flag: bool = 1
    return 0
}
