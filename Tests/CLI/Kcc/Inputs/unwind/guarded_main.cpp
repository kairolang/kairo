// guarded_main.cpp
#include "guarded.k"
#include <iostream>

int main() {
    std::cout << std::unitbuf;
    std::cout << "guarded(5)  = " << guarded::guarded(5) << "\n";    // 11
    std::cout << "guarded(-5) = " << guarded::guarded(-5) << "\n";   // caught, -1
}
