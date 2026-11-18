#pragma once
struct IdS { int v = 3; };
struct IdBag {
    int n;
    IdBag(int x) : n(x) {}
    IdBag(const IdBag& o) : n(o.n + 100) {}   // a copy is observable
    int size() const { return n; }
};
