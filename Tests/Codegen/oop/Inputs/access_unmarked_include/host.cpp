// Corpus for Codegen/oop/access_unmarked_include.k: a C++ host including
// gauge.k. It calls the inline function, which reads the unmarked method as
// a friend, and sees the method private itself.
#include "gauge.k"

template <class G> constexpr bool calls_peek = requires(const G g) { g.peek(); };
static_assert(!calls_peek<gauge::Gauge>, "an unmarked method is private to a C++ host");

#ifdef POKE
int poke(const gauge::Gauge& g) { return g.peek(); }
#endif

int main() {
    gauge::Gauge g;
    return gauge::read(&g) + g.open() - 14;
}
