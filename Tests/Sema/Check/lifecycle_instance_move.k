// An instance of a Kairo generic has lifecycle facts of its own: the
// pattern's fields over the instance's arguments (ClassLifecycle, Instances;
// MONO.md G6). `Opt<Mv>` holds a move-only field, so it is MOVE: `var u = t`
// moves `t`, and reading `t` after it is a use after move. Before G6 the
// instance read its pattern's facts, Unknown, so the copy went through
// unreported to clang's deleted copy constructor. `Opt<i32>` is COPY and
// copies as before. The tuple precedent is move_tuple.k.

class Mv {
    pub var id: i32
    pub fn Mv(self, id: i32) { self.id = id; }
    @move fn Mv(self, other: Self) { self.id = other.id; }
}

class <T> Opt {
    pub var v: T
    pub var some: bool
    fn Opt(self, v: T) { self.v = v; self.some = true; }
}

fn moved() -> bool {
    var t = Opt<Mv>(Mv(7))
    var u = t
    return t.some
// DIAG: lifecycle_instance_move.k:[[@LINE-1]]:12: error [SC052E]: 't' is used after being moved
// DIAG: lifecycle_instance_move.k:[[@LINE-3]]:13: note [I900N]: 't' was moved here, into 'u'
}

fn copied() -> bool {
    var t = Opt<i32>(4)
    var u = t                            // a copy: nothing to report
    return t.some && u.some
}

// A move-only instance passed by value moves too (moves_on_pass).
fn take(o: Opt<Mv>) -> i32 { return o.v.id; }

fn passed() -> i32 {
    var t = Opt<Mv>(Mv(1))
    var n = take(t)
    return n + t.v.id
// DIAG: lifecycle_instance_move.k:[[@LINE-1]]:16: error [SC052E]: 't' is used after being moved
}

fn main() -> i32 { return 0; }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error ["
