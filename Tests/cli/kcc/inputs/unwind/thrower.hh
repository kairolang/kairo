// thrower.hh
#pragma once
#include <stdexcept>

inline int checked_double(int x) {
    if (x < 0) throw std::runtime_error("negative");
    return x * 2;
}