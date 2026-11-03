// See fmt.k. std::to_chars: C++'s fastest standard formatting (shortest
// round-trip for doubles, the same text as Kairo's f-strings).
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

int main() {
    int64_t n = std::atoll(std::getenv("N"));
    char buf[64];
    size_t chars = 0;
    for (int64_t i = 0; i < n; ++i) {
        double d = double(i) * 0.37 + 0.001;
        chars += std::to_chars(buf, buf + sizeof buf, d).ptr - buf;
        chars += std::to_chars(buf, buf + sizeof buf, i * 7919).ptr - buf;
    }
    std::printf("%zu\n", chars);
}
