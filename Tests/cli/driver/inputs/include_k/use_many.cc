#include "geo.k"
#include "twice.k"
#include "shapes.k"
#include "moved.k"
#include "twice.k"

int main() {
    shapes::Point p;
    p.x = 1;
    p.y = 2;
    shapes::Point q = moved::moved(p, 3);
    return geo::add(twice::twice(q.x), shapes::manhattan(q));
}
