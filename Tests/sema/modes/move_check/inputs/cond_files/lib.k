// Imported by main.k: functions that move their argument on one outcome.
pub class Task {
    pub var n: i32 = 0
    pub fn Task(self) { }
    @move pub fn Task(self, other: Self) {
        self.n = other.n
    }
}

pub struct Full {
    pub fn op panic (const self) -> string {
        return "full"
    }
}

pub class Slot {
    pub var t:    Task
    pub var full: bool = false
    pub fn Slot(self) { }

    // Moves `v` only when it returns true.
    pub fn push(self, @inout v: Task) -> bool {
        if self.full {
            return false
        }

        self.t = v
        return true
    }

    // Moves `v` only when it does not return null.
    pub fn put(self, @inout v: Task) -> i32? {
        if self.full {
            return null
        }

        self.t = v
        return 1
    }

    // Moves `v` only when it panics.
    pub fn spill(self, @inout v: Task) panic {
        if self.full {
            self.t = v
            panic Full {}
        }
    }
}
