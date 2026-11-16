// Imports the bridge and no C++ header: the conversions do not exist here.
import self::bridge::*

pub fn plain_len() -> i32 {
    var s: string = "abc"
    return (s.size() + s.doubled()) as i32
}
