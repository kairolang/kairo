// null_main.cpp: a C++ host naming ::builtin::Null<T>, the type Kairo's `T?`
// lowers to, both for values it builds and for values Kairo returns.
#include "cells.k"
#include <iostream>
#include <type_traits>

static_assert(std::is_same_v<decltype(cells::some(1)), ::builtin::Null<int>>, "i32? is ::builtin::Null<int>");
static_assert(std::is_same_v<decltype(cells::cell(1)), ::builtin::Null<cells::Cell>>, "Cell? is ::builtin::Null<Cell>");

int main() {
    ::builtin::Null<int> a = ::builtin::null;
    ::builtin::Null<int> b = 4;
    std::cout << "a null " << a.is_null() << ", b " << b.__value() << "\n";
    std::cout << "or_zero " << cells::or_zero(a) << " " << cells::or_zero(b) << "\n";
    std::cout << "some " << cells::some(6).__value() << ", none null " << cells::none().is_null() << "\n";
    ::builtin::Null<cells::Cell> c = cells::cell(3);
    ::builtin::Null<cells::Cell> d = cells::cell(-1);
    std::cout << "cell " << c.__value().v << ", d null " << d.is_null() << "\n";
    return 0;
}
