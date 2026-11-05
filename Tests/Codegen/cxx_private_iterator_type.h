#pragma once
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
