// A temporary built under an arm of an `if`, `&&` or `||` in the header of a
// `for` loop lives until the loop ends, as every other temporary of the
// header does, and is destroyed once, after the last iteration, only if its
// arm ran. The elements of an array literal in the header are temporaries of
// the header too: a pointer into one is read on every iteration.
//
// Tok counts the objects alive (`live`), the destructions (`deaths`) and the
// iteration the loop was in at the last one (`died_at`).

var live:    i32 = 0
var deaths:  i32 = 0
var step:    i32 = 0
var died_at: i32 = 0

class Tok {
    pub var id: i32

    pub fn Tok(self, id: i32) {
        self.id = id
        live += 1
    }

    @move
    pub fn Tok(self, o: Tok) {
        self.id = o.id
        o.id    = -1
    }

    fn op finally(self) {
        if self.id >= 0 {
            live -= 1
            deaths += 1
            died_at = step
        }
    }

    pub fn view(const self) -> *const Tok {
        return &self
    }

    pub fn ok(const self) -> bool {
        return self.id > 0
    }

    /// Borrows `self` for as long as it runs.
    pub fn count(const self) -> yield i32 {
        for var i = 0; i < 3; i++ {
            yield self.id + i
        }
    }

    /// Borrows `self`; `on` is read once.
    pub fn count_if(const self, on: bool) -> yield i32 {
        if on {
            for var i = 0; i < 2; i++ {
                yield self.id + i
            }
        }
    }
}

fn make(id: i32) -> Tok {
    return Tok(id)
}

fn reset() {
    deaths  = 0
    step    = 0
    died_at = -1
}

fn ended(n: i32, last: i32) -> bool {
    return live == 0 && deaths == n && died_at == last
}

// The then arm is taken: its receiver lives through the loop, the else
// arm's is never built.
fn if_then(c: bool) -> i32 {
    reset()
    var sum = 0
    for x in (if c => make(10).count() else => make(20).count()) {
        step += 1
        if live != 1 {
            return 1
        }

        sum += x
    }

    if sum != 33 || !ended(1, 3) {
        return 2
    }

    return 0
}

fn if_else(c: bool) -> i32 {
    reset()
    var sum = 0
    for x in (if c => make(10).count() else => make(20).count()) {
        step += 1
        if live != 1 {
            return 1
        }

        sum += x
    }

    if sum != 63 || !ended(1, 3) {
        return 2
    }

    return 0
}

fn else_if(k: i32) -> i32 {
    reset()
    var sum = 0
    for x in (if k == 0 => make(10).count() else if k == 1 => make(30).count() else => make(20).count()) {
        step += 1
        if live != 1 {
            return 1
        }

        sum += x
    }

    if sum != 93 || !ended(1, 3) {
        return 2
    }

    return 0
}

// A `break` out of the loop ends the arm's temporary once.
fn if_break(c: bool) -> i32 {
    reset()
    for x in (if c => make(10).count() else => make(20).count()) {
        step += 1
        if live != 1 {
            return 1
        }

        if x == 11 {
            break
        }
    }

    if !ended(1, 2) {
        return 2
    }

    return 0
}

// The right operand of `&&` runs only when the left one is true; its
// temporary then lives with the receiver's.
fn and_arm(c: bool) -> i32 {
    reset()
    var n = 0
    for x in make(10).count_if(c && make(5).ok()) {
        step += 1
        if live != (if c => 2 else => 1) {
            return 1
        }

        n += 1
    }

    if c && (n != 2 || !ended(2, 2)) {
        return 2
    }

    if !c && (n != 0 || !ended(1, 0)) {
        return 3
    }

    return 0
}

fn or_arm(c: bool) -> i32 {
    reset()
    var n = 0
    for x in make(10).count_if(c || make(5).ok()) {
        step += 1
        if live != (if c => 1 else => 2) {
            return 1
        }

        n += 1
    }

    if n != 2 {
        return 2
    }

    if c && !ended(1, 2) {
        return 3
    }

    if !c && !ended(2, 2) {
        return 4
    }

    return 0
}

// The elements of an array literal: pointers into temporaries, read on every
// iteration.
fn array_elements() -> i32 {
    reset()
    var sum = 0
    for p in [make(3).view(), make(4).view()] {
        step += 1
        if live != 2 {
            return 1
        }

        sum += p->id
    }

    if sum != 7 || !ended(2, 2) {
        return 2
    }

    return 0
}

fn main() -> i32 {
    if if_then(true) != 0 {
        return 10 + if_then(true)
    }

    if if_else(false) != 0 {
        return 20 + if_else(false)
    }

    if else_if(1) != 0 {
        return 30 + else_if(1)
    }

    if if_break(true) != 0 {
        return 40 + if_break(true)
    }

    if and_arm(true) != 0 {
        return 50 + and_arm(true)
    }

    if and_arm(false) != 0 {
        return 60 + and_arm(false)
    }

    if or_arm(false) != 0 {
        return 70 + or_arm(false)
    }

    if or_arm(true) != 0 {
        return 80 + or_arm(true)
    }

    if array_elements() != 0 {
        return 90 + array_elements()
    }

    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty --implicit-check-not='error' --implicit-check-not='internal'
// RUN: %t.exe
// DIAG-NOT: error
