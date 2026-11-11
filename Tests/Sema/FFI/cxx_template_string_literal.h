#pragma once
#include <type_traits>
template <class T> int kind(T) {
    static_assert(std::is_same_v<T, const char*>, "T should be const char*");
    return 1;
}
template <class T> int ikind(T) {
    static_assert(std::is_same_v<T, int>, "T should be int");
    return 2;
}
