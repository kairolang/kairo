// Imported by main.k: functions whose record carries a callee's outcome.
pub class Task {
    pub var n: i32 = 0
    pub fn Task(self) { }
    @move pub fn Task(self, other: Self) {
        self.n = other.n
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
}

// Forwards `push`: moves `v` only when it returns true.
pub fn try_push(@inout s: Slot, @inout v: Task) -> bool {
    return s.push(&v)
}

// Forwards `put`: moves `v` only when it does not return null.
pub fn find(@inout s: Slot, @inout v: Task) -> i32? = s.put(&v)

pub struct Full {
    pub fn op panic (const self) -> string {
        return "full"
    }
}

pub struct Other {
    pub fn op panic (const self) -> string {
        return "other"
    }
}

pub fn sink(t: Task) { }

// Moves `v` only when it panics with `Full`.
pub fn spill(@inout v: Task, bad: i32) panic {
    if bad == 1 {
        sink(v)
        panic Full {}
    }

    if bad == 2 {
        panic Other {}
    }
}
