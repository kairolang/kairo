// Support for value_param_other_file.k. Not a test.

pub var made: i32 = 0
pub var ended: i32 = 0
pub var empties: i32 = 0

/// A destructive class whose destructor tells an object that holds a value
/// (`ended`) from a moved-from one (`empties`).
pub class R {
    pub var id: i32 = 0

    pub fn R(self, id: i32) {
        self.id = id
        made += 1
    }

    @move pub fn R(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }

    pub fn op finally(self) {
        if self.id != 0 {
            ended += 1
        } else {
            empties += 1
        }
    }
}

/// Moves its parameter on at every exit.
pub fn take(r: R) -> i32 {
    var mine = r
    return mine.id
}

/// Only reads its parameter.
pub fn peek(r: R) -> i32 = r.id

/// A generic function's body is compiled where it is called.
pub fn <T> wrap(r: R, x: T) -> i32 {
    var mine = r
    return mine.id
}
