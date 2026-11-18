#pragma once
// C++ declarations returning references, for the ffi_ref_return_*.k tests
// Each is defined or overridden in Kairo with `ffi::ref<T>` /
// `ffi::ref<const T>` / `ffi::mref<T>`.
#include <stddef.h>
struct Widget {
    int items[4] = {1, 2, 3, 4};
    int &at(size_t i);
    int at(size_t i) const;
    const int &first() const;
    int &&steal(size_t i);
    int count() const;
};
struct Base {
    int w = 9;
    virtual int &pick() { return w; }
    virtual const int &peek() const { return w; }
    virtual int &&take() { return static_cast<int &&>(w); }
    virtual int val() { return w; }
    virtual ~Base() = default;
};
namespace refs {
int &slot(int &a);
}
