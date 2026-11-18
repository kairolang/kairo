#include "shapes.k"

int main() {
    shapes::Point p;
    p.x = 3;
    p.y = 4;
    int total = shapes::manhattan(p);
    {
        shapes::Tracer t;
        total += t.hit(2);
        total += t.hit(3);
    }
    return total;
}
