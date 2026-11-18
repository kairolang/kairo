// Corpus for ns_reopen.k: `geo` opened in an included header, reopened here,
// and reopened a second time within this header.
#pragma once
#include "ns_part.h"

namespace geo {
int perimeter(int w, int h);
}

namespace geo {
int volume(int w, int h, int d);
}
