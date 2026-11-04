#pragma once
// A derived class's operator* hides the base's (clang calls only the derived
// one), as llvm::iterator_adaptor_base's does under SpecIterator.
template <class T> struct IterBase {
    T *p = nullptr;
    T &operator*() const { return *p; }
};
struct SpecIt : IterBase<int> {
    explicit SpecIt(int *q) { p = q; }
    int *operator*() const { return p; }
};
// A using-declaration keeps the base's operators visible.
struct Merged : IterBase<int> {
    using IterBase<int>::operator*;
    int *operator*() const { return p; }
};
