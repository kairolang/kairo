// Type packs on records: a class, struct or base names its pack as `T...`
// in an argument list, out-of-line members are defined on `Holder<K, T...>`,
// a member through a pack-typed base reads its instance's base, and a member
// may have a pack of its own. A function returns a record over its own pack.

fn <T> one(x: T) -> i32 { return 1 }

class <...T> Base {
    pub var tag: i32
    fn Base(self) { self.tag = 4 }
}

class <K, ...T> Holder derives Base<T...> {
    pub var key: K
    fn Holder(self, k: K) { self.key = k }
    fn <...U> takes(self, ...us: U) -> i32 {
        var n = 0
        for u in us { n += one(u) }
        return n
    }
}

struct <...T> Marker { pub var n: i32 }

fn <...T> wrap(...xs: T) -> Holder<i32, T...> { return Holder<i32, T...>(7) }

fn main() -> i32 {
    var h = Holder<i32, f64, bool>(3)
    var m = Marker<i32, bool>{ n: 2 }
    var w = wrap(1.0, 2)
    return h.key + h.takes(1, 2.0, "x") + m.n + h.tag + w.key   // 3 + 3 + 2 + 4 + 7 = 19
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class K, class ... T> class Holder: public::classes::Base<T ...> {
// CXX: template<class ... T>::classes::Holder<signed int, T ...> wrap(T ... xs) noexcept;
// CXX: template<class ... T> Base<T ...>::Base() noexcept {
// CXX: template<class K, class ... T> Holder<K, T ...>::Holder(K k) noexcept {
// CXX: template<class K, class ... T> template<class ... U> signed int Holder<K, T ...>::takes(U ... us) noexcept {
// CXX: return::classes::Holder<signed int, T ...>(7);
// CXX: ::classes::Holder<signed int, double, signed int> w = ::classes::wrap<double, signed int>(1.0, 2);
// CXX: template class::classes::Holder<signed int, double, bool>;
// CXX: template struct::classes::Marker<signed int, bool>;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 19
