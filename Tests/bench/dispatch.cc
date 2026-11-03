// See dispatch.k.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <vector>

struct Shape { virtual ~Shape() = default; virtual int64_t area() const = 0; };
struct Rect final : Shape { int64_t w, h; Rect(int64_t w, int64_t h) : w(w), h(h) {} int64_t area() const override { return w * h; } };
struct Square final : Shape { int64_t s; explicit Square(int64_t s) : s(s) {} int64_t area() const override { return s * s; } };
struct Tri final : Shape { int64_t b, h; Tri(int64_t b, int64_t h) : b(b), h(h) {} int64_t area() const override { return b * h / 2; } };

int main() {
    int64_t passes = std::atoll(std::getenv("N"));
    std::vector<std::unique_ptr<Shape>> shapes;
    for (int64_t k = 0; k < 1024; ++k) {
        int64_t m = (k * 7919) % 3;
        if (m == 0) shapes.push_back(std::make_unique<Rect>(k % 13 + 1, k % 7 + 1));
        else if (m == 1) shapes.push_back(std::make_unique<Square>(k % 11 + 1));
        else shapes.push_back(std::make_unique<Tri>(k % 17 + 2, k % 5 + 2));
    }
    int64_t total = 0;
    for (int64_t p = 0; p < passes; ++p)
        for (const auto& s : shapes) total += s->area();
    std::printf("%lld\n", (long long)total);
}
