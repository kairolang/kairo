// cmp_main.cpp
#include "ord.k"
#include <algorithm>
#include <iostream>
#include <set>
#include <vector>

int main() {
    ord::Rank a(1), b(2), c(1);
    std::cout << (a < b) << (a <= c) << (b > a) << (a >= b) << (a == c) << (a != b) << "\n";

    std::vector<ord::Rank> rs;
    rs.emplace_back(3);
    rs.emplace_back(1);
    rs.emplace_back(2);
    std::sort(rs.begin(), rs.end());                          // operator<
    for (const auto& r : rs) std::cout << r.n;
    std::cout << "\n";

    std::cout << (std::find(rs.begin(), rs.end(), c) - rs.begin()) << "\n";   // operator==

    std::set<ord::Rank> s(rs.begin(), rs.end());               // std::less
    s.emplace(2);
    std::cout << s.size() << "\n";
}
