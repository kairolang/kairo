#pragma once
// A smart-pointer-like class: `->` goes through operator->.
struct Point { int x; int y; int sum() const { return x + y; } };
struct Handle {
    Point p{2, 3};
    Point *operator->() { return &p; }
    const Point *operator->() const { return &p; }
};
// operator-> returning another class with operator->: C++ chains it.
struct Outer {
    Handle h;
    Handle &operator->() { return h; }
};
