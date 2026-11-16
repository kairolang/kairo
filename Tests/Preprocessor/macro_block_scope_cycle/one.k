import self::two::*

pub macro ONE! { 1 }

pub fn one_val() -> i32 {
    macro arm!(K) { K + TWO! }
    return arm!(1)
}

pub fn one_other() -> i32 {
    macro arm!(K) { K + 100 }
    return arm!(1)
}
