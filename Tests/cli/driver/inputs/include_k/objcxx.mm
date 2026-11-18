#include "geo.k"

@interface Counter
- (int)next;
@end

int run(void) { return geo::add(1, 2); }
