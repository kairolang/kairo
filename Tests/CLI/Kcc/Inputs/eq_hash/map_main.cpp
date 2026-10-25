// map_main.cpp
#include "point.k"
#include <unordered_map>
#include <functional>
#include <iostream>

template <>
struct std::hash<point::Point> {
    std::size_t operator()(const point::Point& p) const noexcept {
        return std::hash<int>{}(p.x) * 31 + std::hash<int>{}(p.y);
    }
};

int main() {
    std::unordered_map<point::Point, int> grid;
    grid[point::Point(1, 2)] = 10;
    grid[point::Point(3, 4)] = 20;
    grid[point::Point(1, 2)] += 5;          // must hit the same key via op ==

    std::cout << "size = " << grid.size() << "\n";                   // 2
    std::cout << "(1,2) = " << grid[point::Point(1, 2)] << "\n";     // 15
    std::cout << "(1,2) != (3,4): " << (point::Point(1,2) != point::Point(3,4)) << "\n"; // 1, C++20 rewrite of !=
}