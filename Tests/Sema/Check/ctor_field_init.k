// A field with no initializer whose type has no default -- `bool`, an enum
// with payloads, a record with no usable default constructor, an array of
// any of those -- is initialized by its record's constructor, as a const
// field is: the constructor's first whole write is its initializer, on
// every path, before `self` is used as a whole (CtorInitCheck). Later
// writes are ordinary assignments. An array field's one whole write in its
// constructor is its initialization; any other whole write of it is SC071E.

enum Frame {
    Burst { base: i32, count: i32 },
    Idle,
}

class Token {
    pub var n: i32
    fn Token(self, n: i32) { self.n = n }
}

// Accepted: each field with no default is built whole first; a later write
// (whole or in part) after `self` is used is an ordinary assignment.
class Ok {
    pub var frame: Frame
    pub var frames: [Frame; 2]
    pub var flag: bool
    pub var tok: Token
    pub var n: i32
    fn Ok(self, c: bool) {
        if c { self.frame = .Idle } else { self.frame = .Burst { base: 1, count: 2 } }
        self.frames = [.Idle, .Idle]
        self.flag = c
        self.tok = Token(3)
        self.bump()
        self.frame = .Idle
        self.frames[1] = .Burst { base: 3, count: 4 }
        self.flag = false
    }
    fn bump(self) { self.n = self.n + 1 }
}

// Accepted: an array field with a declared default, built in the
// constructor instead; and a defaulted transfer constructor, which copies
// every field.
class WithDefault {
    pub var frames: [Frame; 2] = [.Idle, .Idle]
    pub var flag: bool
    fn WithDefault(self) {
        self.frames = [.Burst { base: 1, count: 1 }, .Idle]
        self.flag = true
    }
    @copy fn WithDefault(self, const other: Self) = default
}

class Missing {
    pub var frame: Frame
    fn Missing(self) { }
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: constructor of 'Missing' does not initialize field 'frame', and 'Frame' is an enum with payloads, so no variant is its default
}

class MissingBool {
    pub var flag: bool
    fn MissingBool(self) { }
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: constructor of 'MissingBool' does not initialize field 'flag', and 'bool' has no zero state: a default would have to guess true or false
}

class MissingRecord {
    pub var tok: Token
    fn MissingRecord(self) { }
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: constructor of 'MissingRecord' does not initialize field 'tok', and 'Token' has no default constructor (declare 'fn Token(self)')
}

// The user's report: elements written one by one, the array never built.
class ByElement {
    pub var frames: [Frame; 2]
    fn ByElement(self) {
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: constructor of 'ByElement' does not initialize field 'frames', and 'Frame' is an enum with payloads, so no variant is its default
        self.frames[0] = .Idle
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: note [{{.*}}]: this writes part of 'frames', which does not exist until it is built whole
        self.frames[1] = .Idle
    }
}

class PartFirst {
    pub var frames: [Frame; 2]
    fn PartFirst(self) {
        self.frames[0] = .Idle
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'frames' is written in part before it is initialized, and 'Frame' is an enum with payloads, so no variant is its default
        self.frames = [.Idle, .Idle]
    }
}

class OnePath {
    pub var flag: bool
    fn OnePath(self, c: bool) { if c { self.flag = true } }
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: field 'flag' is not initialized on every path through the constructor of 'OnePath', and 'bool' has no zero state: a default would have to guess true or false
}

class SelfFirst {
    pub var frame: Frame
    fn SelfFirst(self) {
        self.go()
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'self' is used before the constructor has initialized its fields
        self.frame = .Idle
    }
    fn go(self) { }
}

class ArrayTwice {
    pub var frames: [Frame; 2]
    fn ArrayTwice(self) {
        self.frames = [.Idle, .Idle]
        self.frames = [.Idle, .Idle]
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [SC071E]: an array is not assignable; 'frames' may already be initialized here
    }
}

// An array field's first whole write is its initialization even when it has
// a default, so the object exists only after it.
class ArrayLater {
    pub var frames: [i32; 2]
    pub var frame: Frame
    fn ArrayLater(self) {
        self.frame = .Idle
        self.go()
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'self' is used before the constructor has initialized its fields
        self.frames = [1, 2]
    }
    fn go(self) { }
}

class ArrayOnePath {
    pub var frames: [i32; 2]
    fn ArrayOnePath(self, c: bool) { if c { self.frames = [1, 2] } }
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: array field 'frames' is initialized on some paths through the constructor of 'ArrayOnePath' only; an array is not assignable, so its one initialization must be on every path
}

class ArrayLoop {
    pub var frames: [i32; 2]
    fn ArrayLoop(self, n: i32) {
        for var i: i32 = 0; i < n; ++i {
            self.frames = [i, i]
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [SC071E]: array field 'frames' is initialized inside a loop; an array is not assignable, so its one initialization cannot repeat
        }
    }
}

class Defaulted {
    pub var flag: bool
    fn Defaulted(self) = default
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: a defaulted constructor of 'Defaulted' cannot initialize field 'flag', and 'bool' has no zero state: a default would have to guess true or false
}

// Outside a constructor an array is still not assignable.
fn stray(o: *Ok) {
    o->frames = [.Idle, .Idle]
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [SC071E]: an array is not assignable; assign its elements, or go through a slice
}

// A local of an enum with payloads has no default either.
fn local() {
    var f: Frame
// DIAG-DAG: ctor_field_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'f' is declared without an initializer, and 'Frame' is an enum with payloads, so no variant is its default; Kairo has no uninitialized variables
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
