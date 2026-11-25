// Calls Kairo's i256 / u512 functions through `#include "wide.k"`, or through
// the header --emit-headers wrote for it when USE_HEADER is defined.
#ifdef USE_HEADER
#include "wide.hh"
#else
#include "wide.k"
#endif

static_assert(sizeof(unsigned _BitInt(512)) == 64);
static_assert(sizeof(_BitInt(256)) == 32);
#if defined(__aarch64__)
static_assert(alignof(unsigned _BitInt(512)) == 16);
#endif

int main() {
    unsigned _BitInt(512) v = 5;
    v <<= 300;
    _BitInt(256) n = -7;
    return wide::widen(v) == (v << 3) && wide::less(n) == -8 ? 0 : 1;
}
