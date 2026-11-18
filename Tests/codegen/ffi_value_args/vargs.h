// Class templates with non-type parameters of every integral shape: bool,
// a scoped enum, signed (a negative value), unsigned char (a value past
// 127, which clang prints as a character literal), one typed by an earlier
// parameter, and a defaulted one.
#pragma once

template <bool B> struct Flag { int get() const { return B ? 10 : 20; } };

enum class Color : int { Red = 0, Green = 1, Blue = 2 };
template <Color C> struct Paint { int code() const { return static_cast<int>(C) * 100; } };

template <int N> struct Neg { int get() const { return N; } };

template <unsigned char W> struct Narrow { int width() const { return W; } };

template <class T, T V> struct Const { T get() const { return V; } };

template <class T, unsigned N = 3> struct Buf {
    T data[N] = {};
    unsigned cap() const { return N; }
    T& at(unsigned i) { return data[i]; }
};

// A template whose OWN members name an instance with a value argument, so
// that instance is reached through the import, not spelled by the user.
template <class T> struct Holder {
    Buf<T, 2> inner;
    Buf<T, 2>& get() { return inner; }
};
