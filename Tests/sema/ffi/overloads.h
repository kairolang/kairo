// Corpus for overloads.k: C++ overloads, a defaulted parameter, C varargs,
// and an explicit converting constructor.
#pragma once

int    pick(int a);
double pick(double a);

int with_default(int a, int b = 2);

int sum_all(int n, ...);

struct Wrap {
    explicit Wrap(int v);
    Wrap(double d);
    int v;
};

struct Only {
    explicit Only(int v);
    int v;
};
