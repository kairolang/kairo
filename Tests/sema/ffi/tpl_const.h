// Corpus for tpl_const_arg.k: one class template, instantiated at `int` and
// at `const int`.
#pragma once

template <class T> struct W {
    T   v;
    int tag() { return 0; }
};
