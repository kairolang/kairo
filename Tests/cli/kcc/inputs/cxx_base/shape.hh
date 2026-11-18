// shape.hh
#pragma once

struct Shape {
    virtual ~Shape() = default;
    virtual double area() const = 0;
    virtual int sides() const { return 0; }
};

inline double report(const Shape& s) {
    return s.area() + s.sides();
}