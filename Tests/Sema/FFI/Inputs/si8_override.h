#pragma once
struct D { int v = 3; };
struct Base {
    virtual ~Base() {}
    virtual int handle(int lvl, const D &info) { return info.v + lvl; }
    virtual int take(D d) { return d.v; }
};
