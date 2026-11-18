#include "shapes.k"
#include "geo.k"

int side() {
    shapes::Point p;
    p.x = 2;
    p.y = 3;
    return geo::add(shapes::manhattan(p), 1);
}
