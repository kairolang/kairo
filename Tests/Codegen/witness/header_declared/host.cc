// A C++ host instantiating lib's bounded template with lib's own declared
// conformers, none of which any Kairo code pairs with it: the
// specializations come from the declarations alone (CODEGEN.md §7b.6),
// and a generic conformance's partial one covers arguments Kairo never
// named (Wrap<double>, Pod<double>).
#include "lib.hh"
struct Wrong { int b; long scale(long f) const { return b * f; } };
int f() {
    return ::lib::twice(::lib::Metric{3})     // 6
         + ::lib::twice(::lib::Gauge())       // 9
         + ::lib::twice(::lib::Own())         // 3
         + ::lib::twice(::lib::Wrap<double>{1.5}) - 100   // 2
         + ::lib::twice(::lib::Pod<double>(2.5)) - 3;     // 0
}
#ifdef WRONG
int bad() { return ::lib::twice(Wrong{5}); }
#endif
int main() { return f(); }
