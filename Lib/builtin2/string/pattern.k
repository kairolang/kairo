/// builtin/string/pattern.k

import base::intrinsics::*
import string::*

extend char impl Pattern {
    fn find_in(const self, const hay: string, from: usize) -> (usize, usize) {
        __builtin_trap() // BODY-TODO
    }

    fn rfind_in(const self, const hay: string, to: usize) -> (usize, usize) {
        __builtin_trap() // BODY-TODO
    }
}

/// `s.find(Pred { f: is_digit })`
pub struct Pred {
    var f: fn(char) -> bool
}

extend Pred impl Pattern {
    fn find_in(const self, const hay: string, from: usize) -> (usize, usize) {
        __builtin_trap() // BODY-TODO
    }

    fn rfind_in(const self, const hay: string, to: usize) -> (usize, usize) {
        __builtin_trap() // BODY-TODO
    }
}
