// sort_main.cpp
#include "ver.k"
#include <vector>
#include <algorithm>
#include <iostream>

int main() {
    std::vector<ver::Version> vs;
    vs.emplace_back(2, 0);
    vs.emplace_back(1, 9);
    vs.emplace_back(1, 10);
    vs.emplace_back(0, 5);

    std::sort(vs.begin(), vs.end());        // needs a < b from op <=>

    for (const auto& v : vs)
        std::cout << v.major << "." << v.minor << "\n";   // 0.5 1.9 1.10 2.0
}