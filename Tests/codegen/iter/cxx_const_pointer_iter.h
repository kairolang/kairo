// Corpus for cxx_const_pointer_iter_run.k and cxx_const_pointer_iter_err.k.
#pragma once
#include <cstddef>

namespace cp {
// A container whose iterators are raw pointers, `const T*` from the const
// overloads, as llvm::SmallVector's are.
template <class T> struct PtrVec {
    T buf[8];
    size_t n = 0;
    void push_back(const T& v) { buf[n++] = v; }
    T* begin() { return buf; }
    T* end() { return buf + n; }
    const T* begin() const { return buf; }
    const T* end() const { return buf + n; }
};
}
