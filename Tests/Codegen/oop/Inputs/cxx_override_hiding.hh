// Header for Codegen/oop/cxx_override_hiding.k: a C++ base and a C++
// derived class that overrides one virtual, hides one name, and merges
// another back with a using-declaration.
#pragma once
struct CBase {
    virtual int k() { return 1; }
    int f(int) { return 10; }
    int h(int) { return 1; }
    int g(int) { return 100; }
    virtual ~CBase() {}
};
struct CDerived : CBase {
    CDerived() {}
    int k() override { return 2; }
    int f(double) { return 20; }        // hides CBase::f(int)
    double h(double) { return 2.5; }    // hides CBase::h(int)
    using CBase::g;                     // merges CBase::g(int) back
    int g(double) { return 200; }
};
