// passthrough_main.cpp
#include "passthrough.k"
#include <iostream>

int main() {
    std::cout << std::unitbuf;
    std::cout << "pass_through(5) = " << passthrough::pass_through(5) << "\n";   // 11
    try {
        passthrough::pass_through(-5);
    } catch (const std::exception& e) {
        std::cout << "C++ caught through Kairo frame: " << e.what() << "\n";
    }
}
