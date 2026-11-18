#pragma once
#include "fwd.h"
namespace fx {
template <class T> struct Wrap {
    T v;
    Wrap() : v() {}
    explicit Wrap(T x) : v(x) {}
    T get() const { return v; }
    void set(T x) { v = x; }
};
}
