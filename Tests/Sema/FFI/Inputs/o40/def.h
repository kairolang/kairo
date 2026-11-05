#pragma once
#include "fwd.h"
namespace q {
template <class C> struct Str {
    int aaa() const { return 1; }
    int bbb() const { return 2; }
    int cend() const { return 3; }
    static const unsigned long npos = 9;
    unsigned long find() const { return 9; }
};
}
