// shape_main.cpp
#include "shape.hh"
#include "circle.k"
#include <memory>
#include <iostream>

int main() {
    circle::Square sq(2.0);
    std::cout << "C++ report:   " << report(sq) << "\n";            // 8

    std::unique_ptr<Shape> p = std::make_unique<circle::Square>(5.0);
    std::cout << "via base ptr: " << p->area() << "\n";             // 25, virtual dispatch into Kairo

    std::cout << "Kairo report: " << circle::kairo_report() << "\n"; // 13
}   // p deleted through Shape's virtual destructor