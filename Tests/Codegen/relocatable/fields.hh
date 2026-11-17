// C++ types a `@relocatable` Kairo record holds by value in fields.k.
#pragma once

struct CxxTrivial {
    int a;
};

// Trivial for calls, although not trivially copyable: the assignment
// operator is no part of how a value is passed.
struct CxxAssign {
    int a;
    CxxAssign& operator=(const CxxAssign&) { return *this; }
};

struct __attribute__((trivial_abi)) CxxTrivialAbi {
    int a;
    CxxTrivialAbi() : a(0) {}
    CxxTrivialAbi(CxxTrivialAbi&& o) noexcept : a(o.a) {}
    CxxTrivialAbi& operator=(CxxTrivialAbi&& o) noexcept { a = o.a; return *this; }
    ~CxxTrivialAbi() {}
};

// Move-only with every special member trivial.
struct CxxMoveOnly {
    int a;
    CxxMoveOnly() = default;
    CxxMoveOnly(CxxMoveOnly&&) = default;
    CxxMoveOnly& operator=(CxxMoveOnly&&) = default;
};

struct CxxDtor {
    int a;
    ~CxxDtor() {}
};
