#pragma once
// Functions C++ declares returning `int&`, implemented in Kairo.
struct Base {
    int w = 9;
    virtual int &pick() { return w; }
    virtual const int &peek() const { return w; }
    virtual ~Base() = default;
};
inline int use_base(Base &b) { b.pick() = 40; return b.pick() + b.peek(); }
struct S {
    int v = 5;
    int &slot();
};
