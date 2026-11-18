pub class Box {
    pub var v: i32 = 0
    pub fn Box(self) = default

    @copy
    pub fn Box(self, other: Self) {
        self.v = other.v
    }

    pub fn Box(self, v: i32) {
        self.v = v
    }
}

class Holder {
    pub var b: Box
    pub fn Holder(self) = default
}

fn make() -> Box {
    return Box(3)
}

fn take(b: Box) -> i32 {
    return b.v
}

fn peek(const b: Box) -> i32 {
    return b.v
}

fn main() -> i32 {
    var a = Box(1)
    var b = a
    a = b
    var s = take(b)
    s = s + take(Box(10))
    var m = make()
    s = s + peek(Box(4)) + peek(a)
    var h = Holder()
    var h2 = h
    return s + m.v + h2.b.v - 19
}

// --- lit wiring ---
// What such a class can do: copy from a non-const object, and be built in
// place from a temporary (an initializer or a by-value argument is not a
// copy), or bound to a `const` parameter.
// RUN: rm -f %t.exe && rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: %t.exe
