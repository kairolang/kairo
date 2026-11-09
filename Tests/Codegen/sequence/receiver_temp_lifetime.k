// A method chain off a record PRVALUE (`make().first(1)`) whose later
// argument needs pre-statements (an f-string with an adjacent literal) is
// hoisted by SequenceLowering. The pointer `first` returns points into the
// temporary, so the temporary itself must be bound and live to the end of
// the statement; bound only as the pointer, it ended at that pointer's `;` and
// `note`/`emit` ran through a dangling pointer (Stage 1.5's DiagBuilder chains
// all ICE'd "dropped without emit()").
//
// `dropped` counts objects destroyed before `emit()` marked them done: the
// program exits with it, so a premature destruction is a nonzero exit.

var dropped: i32 = 0;

class B {
    pub var done: bool = false;
    fn B(self) { }
    @move fn B(self, other: Self) { self.done = other.done; other.done = true; }
    fn first(self, x: i32) -> unsafe *Self { return unsafe &self; }
    /// A default argument is a thunk call: the receiver is hoisted ahead of
    /// it and bound by value in the call's own block.
    fn first_d(self, x: i32, t: string = "") -> unsafe *Self { return unsafe &self; }
    fn note(self, s: string) -> unsafe *Self { return unsafe &self; }
    fn emit(self) { self.done = true; }
    fn op finally(self) { if !self.done { dropped += 1; } }
}

fn make() -> B { return B(); }

fn main() -> i32 {
    var nm = "v";
    // Hoisted: the f-string argument has pre-statements.
    make().first(1)->note(f"outer '{nm}' declared here; " "rest")->emit();
    // Deeper: the temporary is two steps below the pointer that is hoisted.
    make().first(1)->first(2)->note(f"again '{nm}'")->emit();
    // The receiver bound by value for a default argument's thunk, then a
    // hoisting argument, then a plain chain on the same shape.
    make().first_d(1)->note(f"third '{nm}'" "x")->emit();
    make().first_d(1)->note("plain")->emit();
    // Not hoisted: one full-expression, no pre-statements.
    make().first(1)->note("plain")->emit();
    return dropped;
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -w -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %s -w --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// The prvalue gets its own local before the pointer read off it.
// IR: ::receiver_temp_lifetime::B __kairo_ord{{[0-9]+}} = ::receiver_temp_lifetime::make();
