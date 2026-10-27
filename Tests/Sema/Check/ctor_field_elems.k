// An array field with no default may be built element by element in its
// constructor (CtorInitCheck): `self.f[k] = e` for every k from 0 to N-1,
// each once, with a constant index, outside any loop, before `f` or `self`
// is read. Then f is whole and later element writes are assignments.
// Partial coverage, a duplicate, a non-constant or out-of-range index, a
// loop, or a read before the last element is an error naming what is
// missing. Out of scope, still errors with a note: a write into an element
// (`self.f[0].n = 1`) and an array of arrays.

enum Frame {
    Burst { base: i32, count: i32 },
    Idle,
}

class Token {
    pub var n: i32
    fn Token(self, n: i32) { self.n = n }
}

// Accepted: every element once, in any order, on every path.
class Ok {
    pub var frames: [Frame; 2]
    pub var flags: [bool; 3]
    pub var toks: [Token; 2]
    pub var n: i32
    fn Ok(self, c: bool) {
        self.frames[1] = .Idle
        self.frames[0] = .Burst { base: 1, count: 2 }
        if c {
            self.flags[0] = true
            self.flags[1] = true
            self.flags[2] = false
        } else {
            self.flags[2] = true
            self.flags[0] = false
            self.flags[1] = c
        }
        self.toks[0] = Token(1)
        self.toks[1] = Token(2)
        self.toks[0] = Token(3)
        self.bump()
        self.flags[1] = false
    }
    fn bump(self) { self.n = self.n + 1 }
}

class Partial {
    pub var flags: [bool; 4]
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: note [{{.*}}]: 'flags' has 4 elements; write each one once ('self.flags[k] = ...' for every k from 0 to 3) on every path, or assign it whole
    fn Partial(self, c: bool) {
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: array field 'flags' is built element by element, but elements 1 and 3 are not initialized on every path through the constructor of 'Partial', and 'bool' has no zero state: a default would have to guess true or false
        self.flags[0] = true
        if c { self.flags[1] = true }
        self.flags[2] = true
    }
}

class Twice {
    pub var flags: [bool; 2]
    fn Twice(self) {
        self.flags[0] = true
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: note [{{.*}}]: initialized here first
        self.flags[0] = false
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: element 0 of 'flags' may already be initialized here; each element is initialized exactly once before 'flags' is whole
        self.flags[1] = true
    }
}

class NotConst {
    pub var flags: [bool; 2]
    fn NotConst(self, i: usize) {
        self.flags[i] = true
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: the index of an element write that builds 'flags' must be a constant
        self.flags[1] = true
    }
}

class OutOfRange {
    pub var flags: [bool; 2]
    fn OutOfRange(self) {
        self.flags[2] = true
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: index 2 is out of range for 'flags', which has 2 elements
        self.flags[0] = true
        self.flags[1] = true
    }
}

class InLoop {
    pub var flags: [bool; 2]
    fn InLoop(self) {
        for var i: usize = 0; i < 2; ++i { self.flags[i] = true }
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: an element of 'flags' is initialized inside a loop; each element of an array field built element by element is written exactly once, with a constant index
    }
}

class ReadEarly {
    pub var flags: [bool; 3]
    fn ReadEarly(self) {
        self.flags[0] = true
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: note [{{.*}}]: 'flags' starts being built here; read it after its last element is written
        self.flags[1] = self.flags[0]
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'flags' is read before all of its elements are initialized: elements 1 and 2 are not initialized yet on every path
        self.flags[2] = true
    }
}

class SelfEarly {
    pub var flags: [bool; 2]
    fn SelfEarly(self) {
// DIAG-DAG: ctor_field_elems.k:[[@LINE+4]]:{{[0-9]+}}: note [{{.*}}]: the last field is initialized here; the object exists only after it, so move this use below it
        self.flags[0] = true
        self.go()
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'self' is used before the constructor has initialized its fields
        self.flags[1] = true
    }
    fn go(self) {}
}

class IntoElement {
    pub var toks: [Token; 1]
    fn IntoElement(self) {
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: constructor of 'IntoElement' does not initialize field 'toks', and 'Token' has no default constructor (declare 'fn Token(self)')
        self.toks[0].n = 1
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: note [{{.*}}]: only a whole element written with a constant index ('self.toks[0] = ...') builds part of 'toks'; a write into an element (a field of it, or a nested index) needs the element to exist first
    }
}

class Nested {
    pub var grid: [[bool; 2]; 1]
    fn Nested(self) {
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: constructor of 'Nested' does not initialize field 'grid', and 'bool' has no zero state: a default would have to guess true or false
        self.grid[0] = [true, false]
// DIAG-DAG: ctor_field_elems.k:[[@LINE-1]]:{{[0-9]+}}: note [{{.*}}]: 'grid' cannot be built element by element: only a one-dimensional array of a known length can; assign it whole
// DIAG-DAG: ctor_field_elems.k:[[@LINE-2]]:{{[0-9]+}}: error [SC071E]: an array is not assignable; assign its elements, or go through a slice
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
