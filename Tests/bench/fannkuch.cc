#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <utility>

std::pair<int, int> fannkuch(int n) {
    std::array<int, 16> perm{}, perm1{}, count{};
    for (int i = 0; i < n; ++i) perm1[i] = i;
    int max_flips = 0, checksum = 0, perm_count = 0, r = n;
    while (true) {
        for (; r != 1; --r) count[r - 1] = r;
        perm = perm1;
        int flips = 0;
        for (int k = perm[0]; k != 0; k = perm[0]) {
            std::reverse(perm.begin(), perm.begin() + k + 1);
            ++flips;
        }
        max_flips = std::max(max_flips, flips);
        checksum += (perm_count % 2 == 0) ? flips : -flips;
        while (true) {
            if (r == n) return {checksum, max_flips};
            std::rotate(perm1.begin(), perm1.begin() + 1, perm1.begin() + r + 1);
            if (--count[r] > 0) break;
            ++r;
        }
        ++perm_count;
    }
}

int main() {
    int n = std::atoi(std::getenv("N"));
    auto [checksum, flips] = fannkuch(n);
    std::printf("%d\nPfannkuchen(%d) = %d\n", checksum, n, flips);
}
