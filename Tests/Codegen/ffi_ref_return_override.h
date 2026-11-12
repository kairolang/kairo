#pragma once
// C++ virtuals returning references, overridden in Kairo with
// `ffi::ref<T>` / `ffi::ref<const T>` / `ffi::mref<T>`.
struct Base {
    int w = 9;
    virtual int &pick() { return w; }
    virtual const int &peek() const { return w; }
    virtual int &&take() { return static_cast<int &&>(w); }
    virtual ~Base() = default;
};
// Called from C++ through the base: the override's reference is written
// through, then read back through both virtuals.
inline int poke_base(Base &b) {
    b.pick() = 40;
    b.pick() += 2;
    int moved = static_cast<int &&>(b.take());
    return b.peek() + moved;
}
