// main.cpp
#include "shape.k"
#include <iostream>

// A C++ class completing a Kairo abstract class.
struct Rect : shape::Shape {
    double w, h;
    Rect(double w, double h) : w(w), h(h) {}
    // Kairo methods are noexcept, and an override may not be laxer.
    double area() const noexcept override { return w * h; }
};

int main() {
    Rect r(2.0, 3.0);
    std::cout << "C++ derived via Kairo: " << shape::describe(&r) << "\n";   // 6 + 0
    const shape::Shape& b = r;
    std::cout << "C++ derived via C++:   " << b.area() << "\n";              // 6
    shape::Square sq(4.0);
    std::cout << "Kairo derived via Kairo: " << shape::describe(&sq) << "\n"; // 16 + 4
}
