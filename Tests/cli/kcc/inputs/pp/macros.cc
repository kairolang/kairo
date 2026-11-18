// Host macros never rewrite the Kairo stream: the include is no text
// for the preprocessor to expand. Undone before the C++ uses them.
#define int long
#define add subtract
#define geo nothing
#include "geo.k"
#undef int
#undef add
#undef geo

int main() { return geo::add(40, 2); }
