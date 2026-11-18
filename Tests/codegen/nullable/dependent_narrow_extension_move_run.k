// `if x? { b.push(x) }` on a `J::Item?` in a static of a generic
// extension, where `push` is itself a member of a generic extension
// (`extend <T> Bag<T>`) and `J::Item` is equated with `T` by the
// declaration's `requires`: the narrowed read passes the value, and for a
// MOVE `Item` the value is moved out of the nullable, never copied and
// never the nullable itself.

var made:  i32 = 0
var moves: i32 = 0
var drops: i32 = 0

class Tok {
    pub var v: i64

    pub fn Tok(self, v: i64) {
        self.v = v
        made   += 1
    }

    @move
    pub fn Tok(self, other: Self) {
        self.v  = other.v
        other.v = -1
        moves   += 1
    }

    fn op finally(self) {
        drops += 1
    }
}

class <T> Bag {
    pub var n:   i64
    pub var sum: i64
    pub fn Bag(self) { self.n = 0; self.sum = 0 }
}

extend <T> Bag<T> {
    pub fn push(self, v: T) { self.n += 1 }
}


interface Source {
    type Item
    fn next(self) -> Self::Item?
}

class Two {
    var left: i32
    pub fn Two(self) { self.left = 2 }
}

extend Two impl Source {
    type Item = Tok
    fn next(self) -> Tok? {
        if self.left == 0 { return null }
        self.left -= 1
        return Tok(5)
    }
}

extend <T> Bag<T> {
    pub static fn <J impl Source> fill(it: J) -> i64 requires __builtin_is_same<J::Item, T>() {
        var b = Bag<T>()
        var x = it.next()
        if x? {
            b.push(x)
        }

        x = it.next()
        if !x? {
            return -1
        }

        b.push(x)
        return b.n
    }
}

fn main() -> i32 {
    if Bag<Tok>::fill(Two()) != 2 { return 1 }

    if made != 2 || drops != made + moves { return 2 }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT:  error [
// CXX:      push<T>({{.*}}x.__value()

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
