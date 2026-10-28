// An associated type inherited from a GENERIC interface (MONO.md G5.6 left
// it SC116E): `S::Item` through `S impl IntSource`, IntSource deriving
// `Source<i32>`, is Source's Item at Source<i32> -- the instance the
// composed requirement list says IntSource reaches it through. The same
// through a generic derived interface (`Wrapped<W> derives Source<W>`),
// and `Self::Item` inside the derived interface's own requirement.

interface <V> Source {
    type Item
    fn get(const self) -> Self::Item
    fn tag(const self) -> V
}

interface IntSource derives Source<i32> {
    fn twice(const self) -> Self::Item
}

interface <W> Wrapped derives Source<W> {
    fn more(const self) -> i32
}

class Feed impl IntSource {
    type Item = i64
    fn Feed(self) { }
    fn get(const self) -> i64 { return 30 }
    fn tag(const self) -> i32 { return 2 }
    fn twice(const self) -> i64 { return 60 }
}

class Pipe impl Wrapped<i8> {
    type Item = i16
    fn Pipe(self) { }
    fn get(const self) -> i16 { return 4 }
    fn tag(const self) -> i8 { return 1 }
    fn more(const self) -> i32 { return 5 }
}

fn <S impl IntSource> pull(s: S) -> S::Item { return s.get() }
fn <S impl IntSource> pull2(s: S) -> S::Item { return s.twice() }
fn <S impl Wrapped<i8>> drain(s: S) -> S::Item { return s.get() }

fn main() -> i32 {
    var a: i64 = pull(Feed())
    var b: i64 = pull2(Feed())
    var c: i16 = drain(Pipe())
    return (a + b) as i32 + (c as i32) + Pipe().more()     // 90 + 4 + 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 99
