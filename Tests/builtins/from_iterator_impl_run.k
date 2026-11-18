// A type implements the library's `FromIterator<T>`, whose requirement
// names the interface's parameter in its own clause (`requires
// __builtin_is_same<J::Item, T>()`), and is built from an iterator with the
// size hint the caller passes.

/// Counts down from `hi` to `lo` (exclusive) at the front, up at the back.
class Span {
    var lo: i64
    var hi: i64

    pub fn Span(self, lo: i64, hi: i64) {
        self.lo = lo
        self.hi = hi
    }
}

extend Span impl Iterator {
    type Item = i64
    fn next(self) -> i64? {
        if self.lo == self.hi {
            return null
        }

        self.lo += 1
        return self.lo - 1
    }
}

extend Span impl DoubleEnded {
    fn next_back(self) -> i64? {
        if self.lo == self.hi {
            return null
        }

        self.hi -= 1
        return self.hi
    }
}

extend Span impl ExactSize {
    fn remaining(const self) -> usize = (self.hi - self.lo) as usize
}

/// Sums what it is built from, and keeps the hint it was given.
class Total {
    var sum:  i64
    var hint: usize

    pub fn Total(self) {
        self.sum  = 0
        self.hint = 0
    }
}

extend Total impl FromIterator<i64> {
    static fn <J impl Iterator> from_iter(it: J, hint: usize) -> Total requires __builtin_is_same<J::Item, i64>() {
        var t = Total()
        t.hint = hint
        while true {
            var x = it.next()
            if !x? {
                break
            }

            t.sum += unwrap!(x)
        }

        return t
    }
}

fn main() -> i32 {
    var t = Total::from_iter(Span(1, 4), Span(1, 4).remaining())
    return (t.sum - 6) as i32 + (t.hint - 3) as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
