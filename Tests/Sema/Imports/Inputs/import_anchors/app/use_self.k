import self::util
import self::util::{helper}
import self::util as u
import self::sub::deep
import self::sub::deep::*

pub fn total() -> i32 {
    return util::from_sibling() + helper() + u::helper() + deep::deep_value() + deep_value();
}
