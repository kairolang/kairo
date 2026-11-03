// See closures.k. std::function: the stored, type-erased callback.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>

int main() {
    int64_t n = std::atoll(std::getenv("N"));
    int64_t k1 = 3, k2 = 1000003, k3 = 7;
    std::array<std::function<int64_t(int64_t)>, 3> stages{
        [k1](int64_t x) { return x * k1 + 1; },
        [k2](int64_t x) { return x % k2; },
        [k3](int64_t x) { return x ^ k3; },
    };
    int64_t acc = 0;
    for (int64_t i = 0; i < n; ++i) {
        int64_t v = i;
        for (auto& f : stages) v = f(v);
        acc += v;
    }
    std::printf("%lld\n", (long long)acc);
}
