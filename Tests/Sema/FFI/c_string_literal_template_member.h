// c_string_literal_template_member.k's C++ side: a class template whose
// member takes its element by reference, instantiated at `const char *`.
#pragma once
template <class T> struct Bag {
    int n = 0;
    void push_back(const T &) { ++n; }
    void push_back(T &&) { ++n; }
};
struct Sink { void put(const char *&) {} };
