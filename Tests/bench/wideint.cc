// See wideint.k. unsigned __int128 for the modular multiply.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

using u64 = uint64_t;
using u128 = unsigned __int128;

static u64 mulmod(u64 a, u64 b, u64 m) { return u64(u128(a) * b % m); }
static u64 powmod(u64 b, u64 e, u64 m) {
    u64 r = 1; b %= m;
    while (e) { if (e & 1) r = mulmod(r, b, m); b = mulmod(b, b, m); e >>= 1; }
    return r;
}
static bool is_prime(u64 n) {
    if (n < 2) return false;
    constexpr std::array<u64, 12> small{2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37};
    for (u64 p : small) if (n % p == 0) return n == p;
    u64 d = n - 1; int s = 0;
    while ((d & 1) == 0) { d >>= 1; ++s; }
    for (u64 a : small) {
        u64 x = powmod(a, d, n);
        if (x == 1 || x == n - 1) continue;
        bool composite = true;
        for (int r = 1; r < s; ++r) { x = mulmod(x, x, n); if (x == n - 1) { composite = false; break; } }
        if (composite) return false;
    }
    return true;
}

int main() {
    u64 n = std::strtoull(std::getenv("N"), nullptr, 10), base = u64(1) << 40;
    int count = 0;
    for (u64 k = 0; k < n; ++k) count += is_prime(base + k);
    std::printf("%d\n", count);
}
