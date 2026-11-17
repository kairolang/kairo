// The binder of a loop over a generator's MOVE values is an ordinary local:
// moved onward, it is not read again. A record iterated through its `op in`
// keeps its elements, whether the operator points at them (`-> yield *T`)
// or yields them (`-> yield T`), so a plain binder would copy one.

class Str {
    pub var n: i32 = 0
    pub fn Str(self, n: i32) { self.n = n }
    @move pub fn Str(self, other: Self) { self.n = other.n; other.n = -1 }
}

fn take(s: Str) -> i32 = s.n

fn fresh(n: i32) -> yield Str {
    for var i = 1; i <= n; i++ {
        yield Str(i)
    }
}

class Shelf {
    pub var a: Str
    pub fn Shelf(self) { self.a = Str(1) }

    pub fn op in (self) -> yield *Str {
        yield &self.a
    }
}

class Rack {
    pub var a: Str
    pub fn Rack(self) { self.a = Str(1) }

    pub fn op in (self) -> yield Str {
        yield self.a
    }
}

fn main() -> i32 {
    var sum = 0
    for piece in fresh(3) {
        sum += take(piece)
        sum += piece.n
    }

    var shelf = Shelf()
    for book in shelf {
        sum += book.n
    }

    var rack = Rack()
    for tool in rack {
        sum += tool.n
    }

    return sum
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:  error
// CHECK:      :42:16: error [SC052E]: 'piece' is used after being moved
// CHECK-NEXT: :41:21: note [I900N]: 'piece' was moved here, into a by-value parameter
// CHECK:      :46:9: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: :46:9: note [I900N]: the loop binder 'book' is a copy of each element; bind '*book' for the element's address instead
// CHECK:      :51:9: error [SC182E]: cannot copy a value of type 'Str': it declares a move constructor and no copy constructor
// CHECK-NEXT: :51:9: note [I900N]: the loop binder 'tool' is a copy of each element; its 'op in' yields values; declare it '-> yield *Str' and bind '*tool' for the element's address
// CHECK-NOT:  error [
