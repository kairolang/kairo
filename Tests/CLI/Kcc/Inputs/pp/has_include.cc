#if __has_include("geo.k")
#include "geo.k"
int present() { return geo::add(20, 1); }
#else
int present() { return 0; }
#endif
#if __has_include("absent.k")
#error "absent.k is not there"
#endif

int main() { return present(); }
