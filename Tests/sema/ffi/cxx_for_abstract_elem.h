#pragma once
// A C++ range whose element is an abstract class (toml::array of
// toml::node): binding the element by value is a copy C++ cannot make.
struct Shape { virtual int area() const = 0; virtual ~Shape() {} };
struct Sq : Shape { int s; Sq(int x) : s(x) {} int area() const override { return s * s; } };
struct ShapeIt {
    Sq* p;
    Shape& operator*() const { return *p; }
    ShapeIt& operator++() { ++p; return *this; }
    bool operator!=(const ShapeIt& o) const { return p != o.p; }
};
struct Shapes {
    Sq items[2] = {Sq(2), Sq(3)};
    ShapeIt begin() { return ShapeIt{items}; }
    ShapeIt end() { return ShapeIt{items + 2}; }
};
