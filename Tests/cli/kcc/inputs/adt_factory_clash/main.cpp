// main.cpp: the renamed factories are the ones C++ calls.
#include "shape.k"
#include <iostream>

int main() {
    std::cout << "shape " << shape::shape_code(shape::Shape::Shape_(7)) << "\n";
    std::cout << "is_null " << shape::shape_code(shape::Shape::is_null()) << "\n";
    std::cout << "pt " << shape::shape_code(shape::Shape::Pt(5)) << "\n";
    std::cout << "node " << shape::node_code(shape::Node::Node__(3)) << "\n";
    std::cout << "node_ " << shape::node_code(shape::Node::Node_(4)) << "\n";
}
