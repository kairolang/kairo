// witness/assoc_self_bound.k -- exit 86
// An associated type's bound may name Self, another associated type, or the
// interface's own parameter (interfaces.md, Associated Types): it is read
// through what the associated type was reached by, as everything about it
// is. `type Item impl Has<Self::Key>` is `Has<T::Key>` for `T::Item`, so
// `d.item().key()` is a `T::Key`, read through Key's own bound
// (`k.num()`); `type Item impl Into<V>` in `Source<V>` is `Into<i64>` for an `S
// impl Source<i64>`. Such a bound used to be dropped (it was read only when
// it was not dependent), leaving the member unresolvable.

interface <K> Has { fn key(const self) -> K }
interface Num { fn num(const self) -> i32 }
interface <V> Into { fn into(const self) -> V }

interface Keyed {
    type Key impl Num
    type Item impl Has<Self::Key>
    fn item(const self) -> Self::Item
    fn want(const self) -> Self::Key
}

interface <V> Source {
    type Item impl Into<V>
    fn next(const self) -> Self::Item
}

struct Id { pub var n: i32 }
extend Id impl Num { fn num(const self) -> i32 { return self.n } }
struct Rec { pub var id: Id }
extend Rec impl Has<Id> { fn key(const self) -> Id { return self.id } }

class Db impl Keyed {
    type Key = Id
    type Item = Rec
    pub var w: i32
    fn Db(self, w: i32) { self.w = w }
    fn item(const self) -> Rec { return Rec { id: Id { n: 4 } } }
    fn want(const self) -> Id { return Id { n: self.w } }
}

struct Cell { pub var c: i32 }
extend Cell impl Into<i64> { fn into(const self) -> i64 { return (self.c as i64) * 2 } }
class Gen impl Source<i64> {
    type Item = Cell
    fn Gen(self) { }
    fn next(const self) -> Cell { return Cell { c: 21 } }
}

fn <T impl Keyed> found(d: T) -> i32 {
    var k: T::Key = d.item().key()
    if k.num() == d.want().num() { return 1 }
    return 0
}

fn <S impl Source<i64>> total(s: S) -> i64 {
    var v: i64 = s.next().into()
    return v
}

fn main() -> i32 {
    // 1 + 0 + 42 + 43
    return found(Db(4)) + found(Db(5)) + (total(Gen()) as i32) + 43
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Has_witness<typename{{ ?}}::{{.*}}Keyed_witness<T>::Item, typename{{ ?}}::{{.*}}Keyed_witness<T>::Key>::key(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 86
