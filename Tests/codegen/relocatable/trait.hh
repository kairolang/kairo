// C++ types whose relocatability trait.k asks.
#pragma once

struct __attribute__((trivial_abi)) CxxTrivialAbi {
    int a;
    CxxTrivialAbi() : a(0) {}
    CxxTrivialAbi(CxxTrivialAbi&& o) noexcept : a(o.a) {}
    ~CxxTrivialAbi() {}
};

struct CxxDtor {
    int a;
    ~CxxDtor() {}
};
