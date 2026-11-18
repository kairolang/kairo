#pragma once
// Members of a C++ class and a function in a C++ namespace, declared here
// and DEFINED in Kairo. C++ calls them, so the Kairo definitions
// must be the C++ declarations' own.
#include <stddef.h>
struct Counter {
    int base = 1;
    int get();
    int add(const int &extra) const;
    static int twice(int x);
};
namespace calc {
int inc(int a);
}
inline int from_cxx(Counter &c) { return c.get() + c.add(100) + Counter::twice(3) + calc::inc(1); }
