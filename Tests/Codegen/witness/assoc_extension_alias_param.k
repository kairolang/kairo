// An associated type supplied by a generic extension in terms of the
// extension's own parameter (`extend <I impl Source> Relay<I> impl Source {
// type Item = I::Item }`): at Relay<Gauge> the alias reads through Gauge,
// so Relay<Gauge> conforms with Item = i32, exactly as when the alias is
// declared in the class body over the class's own parameter.

interface Source {
    type Item
    fn get(self) -> Self::Item
}

class Gauge {
    var n: i32 = 5
    fn Gauge(self) { }
}

extend Gauge impl Source {
    type Item = i32
    fn get(self) -> i32 { return self.n }
}

class <I impl Source> Relay {
    var src: I
    fn Relay(self, src: I) { self.src = src }
}

extend <I impl Source> Relay<I> impl Source {
    type Item = I::Item
    fn get(self) -> I::Item { return self.src.get() }
}

class <A impl Source, B impl Source> Pair {
    var a: A
    var b: B
    fn Pair(self, a: A, b: B) {
        self.a = a
        self.b = b
    }
}

extend <A impl Source, B impl Source> Pair<A, B> impl Source {
    type Item = B::Item
    fn get(self) -> B::Item { return self.b.get() }
}

fn <S impl Source> take(s: S) -> S::Item {
    return s.get()
}

fn main() -> i32 {
    var one: i32 = take(Relay<Gauge>(Gauge()))                          // 5
    var two: i32 = take(Relay<Relay<Gauge>>(Relay<Gauge>(Gauge())))     // 5
    var three: i32 = take(Pair<Gauge, Relay<Gauge>>(Gauge(), Relay<Gauge>(Gauge())))
    return one + two + three                                            // 15
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
