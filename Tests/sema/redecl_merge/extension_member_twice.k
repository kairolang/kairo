// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
//
// Every `extend` block of one type in one file adds to one member list, so a
// member that two blocks both declare is declared twice (R041E), as it is
// inside one block. The error is at the later declaration, with a note at the
// earlier one, and a call of the member reports nothing more.

class Counter {
    var n: i32 = 0
}

extend Counter {
    fn next(self) -> i32 {
        return self.n + 1
    }
}

extend Counter {
    fn next(self) -> i32 {
        return self.n + 2
    }
}

// CHECK: extension_member_twice.k:19:5: error [R041E]: class member 'next' cannot be redeclared
// CHECK: extension_member_twice.k:13:5: note [R041N]: previous declaration is here

fn use_next() -> i32 {
    var c = Counter()
    return c.next()
}

interface Show {
    fn show(const self) -> i32
}

interface Size {
    fn size(const self) -> i32
}

class Shape { var w: i32 = 0 }

extend Shape impl Show {
    fn show(const self) -> i32 {
        return 1
    }

    static fn make() -> Shape {
        return Shape()
    }
}

extend Shape impl Size {
    fn size(const self) -> i32 {
        return 2
    }

    static fn make() -> Shape {
        return Shape()
    }
}

// CHECK: extension_member_twice.k:57:5: error [R041E]: class member 'make' cannot be redeclared
// CHECK: extension_member_twice.k:47:5: note [R041N]: previous declaration is here

class Meters { var v: i32 = 0 }

extend Meters {
    fn op as(const self) -> i32 {
        return self.v
    }
}

extend Meters {
    fn op as(const self) -> i32 {
        return 0
    }
}

// CHECK: extension_member_twice.k:74:5: error [R041E]: class member 'op as' cannot be redeclared
// CHECK: extension_member_twice.k:68:5: note [R041N]: previous declaration is here

class <T> Box { var v: T }

extend <T> Box<T> {
    fn tag(self) -> i32 {
        return 1
    }
}

extend <U> Box<U> {
    fn tag(self) -> i32 {
        return 2
    }
}

// CHECK: extension_member_twice.k:91:5: error [R041E]: class member 'tag' cannot be redeclared
// CHECK: extension_member_twice.k:85:5: note [R041N]: previous declaration is here

extend i32 {
    fn twice(self) -> i32 {
        return self * 2
    }
}

extend i32 {
    fn twice(self) -> i32 {
        return self + self
    }
}

// CHECK: extension_member_twice.k:106:5: error [R041E]: class member 'twice' cannot be redeclared
// CHECK: extension_member_twice.k:100:5: note [R041N]: previous declaration is here

module geo {
    pub class Point { pub var x: i32 = 0 }
    extend Point {
        fn half(self) -> i32 {
            return self.x / 2
        }
    }
}

module geo {
    extend Point {
        fn half(self) -> i32 {
            return self.x >> 1
        }
    }
}

// CHECK: extension_member_twice.k:125:9: error [R041E]: class member 'half' cannot be redeclared
// CHECK: extension_member_twice.k:117:9: note [R041N]: previous declaration is here

fn main() -> i32 {
    return use_next()
}
