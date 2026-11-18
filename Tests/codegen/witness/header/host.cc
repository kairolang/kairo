// A C++ host instantiating a Kairo bounded template through its header.
// `Own` has an exact own `scale`: the primary serves it. `Wrong`'s takes a
// long: the primary's exact-signature gate rejects it, and the call fails
// at the concept rather than compiling a different witness (§7b.3).
#include "iface.hh"
struct Own { int b; int scale(int f) const { return b * f; } };
struct Wrong { int b; long scale(long f) const { return b * f; } };
int ok() { return ::iface::twice(Own{5}); }
#ifdef WRONG
int bad() { return ::iface::twice(Wrong{5}); }
#endif
