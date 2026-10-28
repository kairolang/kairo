// guarded_main.cpp
#include "guarded.k"
#include <iostream>

int main() {
    std::cout << std::unitbuf;
    std::cout << "guarded(5)  = " << guarded::guarded(5) << "\n";    // 11
    int r = guarded::guarded(-5);                                       // caught, -1: Kairo prints first
    std::cout << "guarded(-5) = " << r << "\n";
}
