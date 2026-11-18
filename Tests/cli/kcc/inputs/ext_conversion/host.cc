#include "units.k"

#include <type_traits>

// The Kairo side converts (in_meters); C++ is given no conversion.
static_assert(!std::is_convertible_v<units::Feet, units::Meters>,
              "an extension's op as is not a C++ conversion function");
static_assert(!std::is_constructible_v<units::Meters, units::Feet>,
              "an extension's op as is not a C++ conversion function");

int main() { return units::in_meters(units::feet(9)); }
