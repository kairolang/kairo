#pragma once
#include <type_traits>
// A C++ container whose iterator type is a private/protected member alias of
// the class, reachable only through public begin()/end()/range accessors.
class Bag {
    struct Iter {
        int *p;
        int &operator*() const { return *p; }
        Iter &operator++() { ++p; return *this; }
        bool operator!=(const Iter &o) const { return p != o.p; }
        bool operator==(const Iter &o) const { return p == o.p; }
    };
    int data[3] = {1, 2, 3};
public:
    Iter begin() { return Iter{data}; }
    Iter end() { return Iter{data + 3}; }
};
class Base {
protected:
    struct PIter {
        int *p;
        int &operator*() const { return *p; }
        PIter &operator++() { ++p; return *this; }
        bool operator!=(const PIter &o) const { return p != o.p; }
    };
    int data[2] = {10, 20};
public:
    PIter begin() { return PIter{data}; }
    PIter end() { return PIter{data + 2}; }
};
// A protected member class template, named only inside a public range type
// (clang::RedeclarableTemplateDecl::SpecIterator inside specializations()).
template <class I> struct PubRange {
    I b, e;
    I begin() const { return b; }
    I end() const { return e; }
};
class Holder {
protected:
    template <class E> struct Cur {
        E *p;
        E &operator*() const { return *p; }
        Cur &operator++() { ++p; return *this; }
        bool operator!=(const Cur &o) const { return p != o.p; }
    };
    int data[2] = {1, 2};
public:
    PubRange<Cur<int>> items() { return PubRange<Cur<int>>{Cur<int>{data}, Cur<int>{data + 2}}; }
};
// Derived: the hidden type belongs to a BASE of the class the call is on.
class Derived : public Holder {};
class CmpBag {
    struct It {
        int *p;
        bool operator==(const It &o) const { return p == o.p; }
        bool operator!=(const It &o) const { return p != o.p; }
    };
    int data[2] = {1, 2};
public:
    It find(int k) { return It{data + (k == 1 ? 0 : 2)}; }
    It end() { return It{data + 2}; }
};
// llvm::DenseSet's shape: a private iterator template, compared through a
// FREE operator== on its const form, so the call's arguments are cast to a
// parameter type that names the private template.
class Set {
    template <bool C> class Iter2 {
    public:
        const int *p;
        Iter2(const int *q) : p(q) {}
        template <bool D, class = typename std::enable_if<C && !D>::type>
        Iter2(const Iter2<D> &o) : p(o.p) {}
        friend bool operator==(const Iter2<C> &a, const Iter2<C> &b) { return a.p == b.p; }
        friend bool operator!=(const Iter2<C> &a, const Iter2<C> &b) { return a.p != b.p; }
    };
    int data[2] = {1, 2};
public:
    using iterator = Iter2<false>;
    using const_iterator = Iter2<true>;
    iterator find(int k) { return iterator(data + (k == 1 ? 0 : 2)); }
    iterator end() { return iterator(data + 2); }
    const_iterator end() const { return const_iterator(data + 2); }
};
