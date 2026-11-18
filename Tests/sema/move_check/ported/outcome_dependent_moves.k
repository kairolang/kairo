// A function that moves its argument only on one outcome leaves it moved-from
// only on that outcome. Three outcomes are told apart: returning `true` or
// `false`, returning `null` or a value, and panicking or returning. The
// caller sees the outcome when the call is itself the condition of an `if`
// or a loop, alone or under `!`, `&&`, `||`, `?`, `== null` or `!= null`,
// and in the `catch` arms of a `try`; a local initialised from the call
// carries it until it is tested. Anywhere else the argument counts as moved
// (ownership.mdx, Moved-From State).
// Cases from Rust tests/ui/drop/drop-once-on-move, conditional-drop-10734,
// moves/move-3-unique.

class Task {
    pub var id: i32 = 0
    fn Task(self, id: i32) { self.id = id }
    @move fn Task(self, other: Self) { self.id = other.id; other.id = 0 }
}

struct Full { var n: i32 }
struct Other { var n: i32 }

class Queue {
    pub var slot: Task
    pub var used: bool = false
    fn Queue(self) { self.slot = Task(0) }

    fn push(self, @inout v: Task) -> bool {
        if self.used { return false }
        self.slot = v
        self.used = true
        return true
    }

    fn try_take(self, @inout v: Task) -> Task? {
        if self.used { return null }
        self.slot = v
        self.used = true
        return Task(9)
    }

    fn give(self, @inout v: Task) panic(Full) {
        if self.used { panic Full { n: 1 } }
        self.slot = v
        self.used = true
    }
}

fn if_true_branch_is_moved(q: *Queue) -> i32 {
    var t = Task(1)
    if q->push(&t) {
        return 0
    } else {
        return t.id
    }
}

fn if_true_branch_read(q: *Queue) -> i32 {
    var t = Task(1)
    if q->push(&t) {
        return t.id //! SC052E
    }
    return 0
}

fn negated_condition(q: *Queue) -> i32 {
    var t = Task(1)
    if !q->push(&t) {
        return t.id
    }
    return 0
}

fn negated_condition_else_read(q: *Queue) -> i32 {
    var t = Task(1)
    if !q->push(&t) {
        return 0
    } else {
        return t.id //! SC052E
    }
}

fn while_not_push_loop(q: *Queue) -> i32 {
    var t = Task(1)
    while !q->push(&t) {
        var n = t.id
    }
    return t.id //! SC052E
}

fn while_not_push_body_is_whole(q: *Queue) -> i32 {
    var t = Task(1)
    var n = 0
    while !q->push(&t) {
        n += t.id
    }
    return n
}

fn local_carries_outcome(q: *Queue) -> i32 {
    var t = Task(1)
    var ok = q->push(&t)
    if !ok {
        return t.id
    }
    return 0
}

fn local_untested_counts_as_moved(q: *Queue) -> i32 {
    var t = Task(1)
    var ok = q->push(&t)
    return t.id //! SC052E
}

fn result_passed_on_counts_as_moved(q: *Queue) -> bool {
    var t = Task(1)
    var r = q->push(&t)
    return use_bool(r) && t.id > 0 //! SC052E
}

fn use_bool(b: bool) -> bool { return b }

fn and_condition(q: *Queue, c: bool) -> i32 {
    var t = Task(1)
    if c && q->push(&t) {
        return 0
    }
    return t.id
}

fn and_condition_falls_through(q: *Queue, c: bool) -> i32 {
    var t = Task(1)
    if c && q->push(&t) {
        var n = 0
    }
    return t.id //! SC052E
}

fn or_condition(q: *Queue, c: bool) -> i32 {
    var t = Task(1)
    if c || q->push(&t) {
        return 0
    }
    return t.id
}

fn nullable_outcome_null_branch(q: *Queue) -> i32 {
    var t = Task(1)
    var r = q->try_take(&t)
    if r == null {
        return t.id
    }
    return 0
}

fn nullable_outcome_value_branch(q: *Queue) -> i32 {
    var t = Task(1)
    if q->try_take(&t) != null {
        return t.id //! SC052E
    }
    return 0
}

fn panic_outcome_catch_other_type(q: *Queue) -> i32 {
    var t = Task(1)
    try {
        q->give(&t)
    } catch e: Full {
        return t.id
    }
    return 0
}

fn panic_outcome_after_try_is_moved(q: *Queue) -> i32 {
    var t = Task(1)
    try {
        q->give(&t)
    } catch e: Full {
        var n = 1
    }
    return t.id //! SC052E
}

fn returned_call_result_moves_on_same_outcome(q: *Queue, v: Task) -> bool {
    return q->push(&v)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: outcome_dependent_moves.k:59:{{[0-9]+}}: error [SC052E]:
// CHECK: outcome_dependent_moves.k:77:{{[0-9]+}}: error [SC052E]:
// CHECK: outcome_dependent_moves.k:86:{{[0-9]+}}: error [SC052E]:
// CHECK: outcome_dependent_moves.k:110:{{[0-9]+}}: error [SC052E]:
// CHECK: outcome_dependent_moves.k:116:{{[0-9]+}}: error [SC052E]:
// CHECK: outcome_dependent_moves.k:134:{{[0-9]+}}: error [SC052E]:
// CHECK: outcome_dependent_moves.k:157:{{[0-9]+}}: error [SC052E]:
// CHECK: outcome_dependent_moves.k:179:{{[0-9]+}}: error [SC052E]:
