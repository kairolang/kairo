#include "moved.k"
#include "greet.k"
#include "shapes.k"
#include "twice.k"
#include "geo.k"

int main() {
    shapes::Point p;
    p.x = 1;
    p.y = 2;
    shapes::Point q = moved::moved(p, 3);
    {
        shapes::Tracer t;
        t.hit(1);
    }
    return geo::add(twice::twice(q.x), greet::greet(shapes::manhattan(q)));
}
