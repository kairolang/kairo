// C++ classes deriving the Kairo ones in shapes.k, each dispatched through a
// Kairo function whose virtual call is versioned: shapes::area_of compares
// the vptr with the Kairo vtables, shapes::level_of the slot with the bodies.
#include "shapes.k"
#include <cstdio>

// A C++ override: its slot matches no compare and takes the indirect call.
struct Hex : shapes::Shape {
    long area() const noexcept override { return 600; }
};

// Derives a Kairo subclass and overrides it again.
struct BigSquare : shapes::Square {
    BigSquare() : shapes::Square(3) {}
    long area() const noexcept override { return 7000; }
};

// No override: its own vtable matches no compare, and the indirect call
// reaches Shape's Kairo body.
struct Plain : shapes::Shape {};

// No override of Meter: the slot holds Meter's Kairo body, which one arm runs.
struct PlainMeter : shapes::Meter {};

// A C++ override under slot compares: it matches no body, so the indirect
// call runs it.
struct Dial : shapes::Gauge {
    long level() const noexcept override { return 400; }
};

int main() {
    Hex h;
    BigSquare b;
    Plain p;
    shapes::Rect r(2, 5);
    shapes::Square s(4);
    std::printf("%ld %ld %ld %ld %ld\n", shapes::area_of(&h), shapes::area_of(&b),
                shapes::area_of(&p), shapes::area_of(&r), shapes::area_of(&s));
    PlainMeter pm;
    Dial d;
    shapes::M1 m1;
    shapes::Gauge g;
    std::printf("%ld %ld %ld %ld\n", shapes::level_of(&pm), shapes::level_of(&d),
                shapes::level_of(&m1), shapes::level_of(&g));
    return 0;
}
