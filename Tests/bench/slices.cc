// See slices.k.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static std::array<double, 1048576> xs, ys;

int main() {
    int64_t passes = std::atoll(std::getenv("N"));
    for (size_t i = 0; i < xs.size(); ++i) { xs[i] = double(i % 1000) * 0.5; ys[i] = double(i % 37) * 0.25; }
    double sum = 0, dot = 0;
    int64_t big = 0;
    for (int64_t p = 0; p < passes; ++p) {
        for (double x : xs) sum += x;
        for (size_t i = 0; i < xs.size(); ++i) dot += xs[i] * ys[i];
        for (double y : ys) if (y > 4.0) ++big;
    }
    std::printf("%lld %lld %lld\n", (long long)sum, (long long)dot, (long long)big);
}
