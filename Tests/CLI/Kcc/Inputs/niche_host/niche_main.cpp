// niche_main.cpp: two Kairo modules included into one C++ TU, each with
// enums, so each include needs the niche trait; it is written once. A C++
// host then sees Kairo's niche layouts exactly as Kairo does.
#include "colors.k"
#include "shapes.k"
#include <cstdio>

using ::builtin::Nullable;

static_assert(sizeof(Nullable<colors::Color>) == 1, "Color? is one byte: null is 3");
static_assert(sizeof(Nullable<colors::Pixel*>) == sizeof(colors::Pixel*), "a nullable pointer is the pointer");
static_assert(sizeof(colors::Slot) == sizeof(colors::Pixel*), "Slot is niche-filled");
static_assert(sizeof(shapes::Mark) == sizeof(shapes::Kind), "Mark stores Clear as Kind 3");

int main() {
    Nullable<colors::Color> n = ::builtin::null;
    Nullable<colors::Color> g = colors::Color::Green;
    colors::Pixel px{};
    Nullable<colors::Pixel*> p = &px;
    Nullable<colors::Pixel*> q;
    std::printf("n %d g %d p %d q %d\n", n.is_null(), g.is_null(), p.is_null(), q.is_null());
    return 0;
}
