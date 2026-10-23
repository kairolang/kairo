// A const field with no initializer at its declaration is initialized
// exactly once, by its record's constructor, on every path, before `self`
// is used as a whole (CtorInitCheck). One with an initializer is never
// assigned, and outside a constructor of its own record no const field is
// assigned at all. A record with a const field cannot be assigned member by
// member.

fn twice(n: i32) -> i32 { return n * 2 }

// Accepted: both branches initialize x.
class Ok {
    pub const x: i32
    fn Ok(self, x: i32) { if x < 0 { self.x = 0 } else { self.x = x } }
}

// Accepted: a var field on one path, a carried local, a read of a const
// already initialized, `self` used after the last const field.
class Interleaved {
    pub const port: i32
    pub const scale: i32
    pub var retries: i32 = 3
    pub var log: i32 = 0
    fn Interleaved(self, p: i32, env: bool) {
        var base = twice(p)
        if env {
            self.port = base
            self.retries = 5
        } else {
            self.port = p
        }
        self.scale = self.port + 1
        self.log = base + self.scale
        self.bump()
    }
    fn bump(self) { self.log = self.log + 1 }
}

class Missing {
    pub const x: i32
    fn Missing(self) { }
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: constructor of 'Missing' does not initialize const field 'x'
}

class OnePath {
    pub const x: i32
    fn OnePath(self, c: bool) { if c { self.x = 1 } }
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: const field 'x' is not initialized on every path through the constructor of 'OnePath'
}

class Twice {
    pub const x: i32
    fn Twice(self) {
        self.x = 1
        self.x = 2
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: const field 'x' may already be initialized here; a const field is initialized exactly once
    }
}

class InLoop {
    pub const x: i32
    fn InLoop(self, n: i32) {
        var i = 0
        while i < n {
            self.x = i
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: const field 'x' is initialized inside a loop, which may run more than once or not at all
            i += 1
        }
    }
}

class HasDefault {
    pub const x: i32 = 4
    fn HasDefault(self) { self.x = 5 }
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: const field 'x' has an initializer at its declaration, so the constructor cannot assign it
}

class EarlySelf {
    pub const x: i32
    fn EarlySelf(self) {
        self.touch()
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'self' is used before every const field is initialized
        self.x = 1
    }
    fn touch(self) { }
}

class ReadUnbuilt {
    pub const x: i32
    pub var y: i32 = 7
    fn ReadUnbuilt(self) {
        var t = self.y
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'y' cannot be read before every const field is initialized: the object does not exist yet
        self.x = t
    }
}

class ReadEarly {
    pub const x: i32
    pub var y: i32 = 0
    fn ReadEarly(self) {
        self.y = self.x
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: 'x' is read before it is initialized on every path
        self.x = 1
    }
}

class EarlyReturn {
    pub const x: i32
    fn EarlyReturn(self, c: bool) {
        if c { return }
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: a constructor cannot return before its last const field is initialized
        self.x = 1
    }
}

class Defaulted {
    pub const x: i32
    fn Defaulted(self) = default
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: a defaulted constructor of 'Defaulted' cannot initialize const field 'x'
}

class Generic {
    pub const x: i32
    fn <T> Generic(self, v: T) { self.x = 1 }
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [SC116E]: a generic constructor that initializes a const field is not yet supported
}

fn stray(o: *Ok) {
    o->x = 3
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [{{SC0*1E}}]: cannot assign to const field 'x'
}

fn reassign() {
    var a = Ok(1)
    var b = Ok(2)
    a = b
// DIAG-DAG: ctor_const_init.k:[[@LINE-1]]:{{[0-9]+}}: error [SC071E]: cannot assign a '{{.*}}Ok': its field 'x' is const
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
