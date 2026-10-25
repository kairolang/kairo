// A C++ host instantiating lib's bounded template with lib's own declared
// conformers, none of which any Kairo code pairs with it: the
// specializations come from the declarations alone (CODEGEN.md §7b.6).
#include "lib.hh"
struct Wrong { int b; long scale(long f) const { return b * f; } };
int f() {
    return ::lib::twice(::lib::Metric{3})     // 6
         + ::lib::twice(::lib::Gauge())       // 9
         + ::lib::twice(::lib::Own());        // 3
}
#ifdef WRONG
int bad() { return ::lib::twice(Wrong{5}); }
#endif
int main() { return f(); }
