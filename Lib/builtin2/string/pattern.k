/// builtin/string/pattern.k

import base::intrinsics::*
import string::*

/// A char matches its UTF-8 form: one byte for ASCII, found a word at a time.
extend char impl Pattern {
    fn find_in(const self, const hay: string, from: usize) -> (usize, usize) {
        var buf: [u8; 4] = [0, 0, 0, 0]
        unsafe {
            var n = string::encode_(self, &buf[0] as unsafe *u8)
            return string::view_of_(const &buf[0], n).find_in(hay, from)
        }
    }

    fn rfind_in(const self, const hay: string, to: usize) -> (usize, usize) {
        var buf: [u8; 4] = [0, 0, 0, 0]
        unsafe {
            var n = string::encode_(self, &buf[0] as unsafe *u8)
            return string::view_of_(const &buf[0], n).rfind_in(hay, to)
        }
    }
}

/// `s.find(Pred { f: is_digit })`
pub struct Pred {
    var f: fn(char) -> bool
}

/// Matches one char the predicate accepts. A `from` or a `to` inside a
/// char moves to the next boundary in the direction of the search.
extend Pred impl Pattern {
    fn find_in(const self, const hay: string, from: usize) -> (usize, usize) {
        var n = hay.size()
        var i = from
        while i < n && !hay.is_char_boundary(i) {
            i += 1
        }

        while i < n {
            var (c, w) = hay.decode_at_(i)
            if self.f(c) {
                return (i, w)
            }

            i += w
        }

        return (NO_MATCH, 0)
    }

    fn rfind_in(const self, const hay: string, to: usize) -> (usize, usize) {
        var i = to
        if i > hay.size() {
            i = hay.size()
        }

        while i > 0 && !hay.is_char_boundary(i) {
            i -= 1
        }

        while i > 0 {
            var (c, w) = hay.decode_before_(i)
            i -= w
            if self.f(c) {
                return (i, w)
            }
        }

        return (NO_MATCH, 0)
    }
}
