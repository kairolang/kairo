#pragma once
#include <vector>

template <class T> struct Bag {
    std::vector<T> v;
    void put(T t) { v.push_back(t); }
    T first() const { return v[0]; }
    static int count() { return 0; }
};
