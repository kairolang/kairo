#include "geo.k"
#include "shapes.k"

int side();

int main() {
    shapes::Point p;
    p.x = 1;
    p.y = 1;
    return side() + shapes::manhattan(p) + geo::add(0, 1);
}
