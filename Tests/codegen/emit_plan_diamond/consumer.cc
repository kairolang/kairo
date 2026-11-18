#include <cstdint>
#include "geo/render.hh"
#include "geo/text.hh"

int main() {
    geo::text::Label l{};
    return static_cast<int>(geo::render::place(l) + geo::render::boxed(1.0).get());
}
