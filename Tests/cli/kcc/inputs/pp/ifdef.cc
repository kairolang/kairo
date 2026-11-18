#ifdef USE_GEO
#include "geo.k"
int pick() { return geo::add(30, 3); }
#else
int pick() { return 1; }
#endif

int main() { return pick(); }
