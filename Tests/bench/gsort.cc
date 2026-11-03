#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>

struct Key { int64_t v; bool operator<(const Key& o) const { return v < o.v; } };
struct Pair { int64_t key; int32_t val; bool operator<(const Pair& o) const { return key < o.key; } };

template <class T> void insertion(T* a, ptrdiff_t lo, ptrdiff_t hi) {
    for (ptrdiff_t i = lo + 1; i <= hi; ++i) {
        T v = a[i]; ptrdiff_t j = i - 1;
        while (j >= lo && v < a[j]) { a[j + 1] = a[j]; --j; }
        a[j + 1] = v;
    }
}
template <class T> void quicksort(T* a, ptrdiff_t lo, ptrdiff_t hi) {
    while (hi - lo > 16) {
        ptrdiff_t mid = lo + (hi - lo) / 2;
        if (a[mid] < a[lo]) std::swap(a[mid], a[lo]);
        if (a[hi] < a[lo]) std::swap(a[hi], a[lo]);
        if (a[hi] < a[mid]) std::swap(a[hi], a[mid]);
        T pivot = a[mid];
        ptrdiff_t i = lo, j = hi;
        while (i <= j) {
            while (a[i] < pivot) ++i;
            while (pivot < a[j]) --j;
            if (i <= j) { std::swap(a[i], a[j]); ++i; --j; }
        }
        if (j - lo < hi - i) { quicksort(a, lo, j); lo = i; } else { quicksort(a, i, hi); hi = j; }
    }
    insertion(a, lo, hi);
}
template <class T, class R, class F> R reduce(const T* a, ptrdiff_t n, R init, F f) {
    for (ptrdiff_t i = 0; i < n; ++i) init = f(init, a[i]);
    return init;
}
template <class T, class P> int64_t count_if(const T* a, ptrdiff_t n, P pred) {
    int64_t c = 0; for (ptrdiff_t i = 0; i < n; ++i) c += pred(a[i]); return c;
}

static uint64_t rng = 0x9E3779B97F4A7C15ull;
uint64_t next_rand() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

int main() {
    ptrdiff_t n = std::atol(std::getenv("N"));
    bool lib = std::getenv("LIBSORT") != nullptr;
    auto xs = std::make_unique<Key[]>(n);
    auto ps = std::make_unique<Pair[]>(n);
    for (ptrdiff_t i = 0; i < n; ++i) { uint64_t r = next_rand(); xs[i] = {int64_t(r >> 1)}; ps[i] = {int64_t(r >> 20), int32_t(i)}; }
    if (lib) { std::sort(xs.get(), xs.get() + n); std::sort(ps.get(), ps.get() + n); }
    else { quicksort(xs.get(), 0, n - 1); quicksort(ps.get(), 0, n - 1); }
    bool sorted = true;
    for (ptrdiff_t i = 1; i < n; ++i) if (xs[i] < xs[i - 1] || ps[i].key < ps[i - 1].key) sorted = false;
    int64_t sum = reduce(xs.get(), n, int64_t(0), [](int64_t acc, Key k) { return acc ^ (k.v + acc); });
    int64_t big = count_if(ps.get(), n, [](const Pair& p) { return p.val % 3 == 0; });
    std::printf("sorted %s sum %lld count %lld\n", sorted ? "true" : "false", (long long)sum, (long long)big);
}
