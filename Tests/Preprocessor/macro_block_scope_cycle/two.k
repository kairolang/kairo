import self::one::*

pub macro TWO! { 2 }

pub fn two_val() -> i32 {
    macro arm!(K) { K + ONE! + 10 }
    return arm!(1)
}
