// Corpus for Codegen/oop/access_derives_narrowing.k: a C++ host sees the
// narrowing of `derives priv` / `derives prot` and keeps the conversions.
#include "access_narrow_lib.k"

using namespace access_narrow_lib;
template <class T> constexpr bool reads_x = requires(T t) { t.x; };
template <class T> constexpr bool calls_f = requires(const T t) { t.f(); };
static_assert(reads_x<V> && calls_f<V>, "V's own members are public through a V");
static_assert(!reads_x<S> && !calls_f<S>, "`derives priv V` makes them private through an S");
static_assert(!reads_x<P> && !calls_f<P>, "`derives prot V` makes them protected through a P");
static_assert(__is_convertible(S*, V*) && __is_convertible(P*, V*), "the bases stay public");

int main() {
    S s;
    V* v = &s;
    return (v->x == 1 && dynamic_cast<S*>(v) == &s && lib_sum(&s) == 11) ? 0 : 1;
}
