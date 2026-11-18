#pragma once
struct LS {
    enum Kind { a = 3, b = 5 };
    int pad = 0;
};
inline int setk(LS::Kind k) { return k; }
