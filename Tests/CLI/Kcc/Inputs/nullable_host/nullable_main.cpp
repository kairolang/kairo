// nullable_main.cpp: a C++ host building and testing ::builtin::Nullable,
// the type Kairo's `T?` lowers to, from both of its constructors.
#include "widgets.k"
#include <iostream>
#include <type_traits>
#include <utility>

using ::builtin::Nullable;

static_assert(!std::is_copy_constructible_v<Nullable<widgets::Uniq>>, "a Nullable of a move-only type is move-only");
static_assert(std::is_move_constructible_v<Nullable<widgets::Uniq>>, "and still movable");
static_assert(std::is_copy_constructible_v<Nullable<widgets::Widget>>, "a Nullable of a copyable type copies");
static_assert(!std::is_default_constructible_v<widgets::Widget>, "the payload has no default constructor");

int main() {
    std::cout << std::unitbuf;
    Nullable<int> a = ::builtin::null;
    Nullable<int> b = 5;
    Nullable<int> c = 5;
    Nullable<int> d;
    std::cout << "a null " << a.is_null() << ", b null " << b.is_null() << ", d null " << d.is_null() << "\n";
    std::cout << "b == c " << (b == c) << ", a == b " << (a == b) << ", a == d " << (a == d)
              << ", b != a " << (b != a) << ", b == 5 " << (b == 5) << ", a == null " << (a == ::builtin::null) << "\n";
    std::cout << "b value " << b.__value() << "\n";
    b = ::builtin::null;
    std::cout << "b null after reset " << b.is_null() << "\n";

    std::cout << "widgets\n";
    {
        Nullable<widgets::Widget> none = ::builtin::null;   // no Widget exists: nothing to destroy
        Nullable<widgets::Widget> one = widgets::Widget(7); // Widget is COPY: the temporary is copied in, then dies (~Widget 7)
        std::cout << "one holds " << one.__value().id << ", none null " << none.is_null() << "\n";
        Nullable<widgets::Widget> two = one;                // a copy: a second live Widget 7
        std::cout << "copy equal " << (one == two) << "\n";
        two = widgets::Widget(8);                           // the copy replaced (~Widget 7), then the temporary
                                                            // Nullable and Widget it was built through (~Widget 8 twice)
        std::cout << "replaced\n";
    }                                                       // ~Widget 8, ~Widget 7
    std::cout << "from kairo\n";
    {
        Nullable<widgets::Widget> k = widgets::boxed(9);
        std::cout << "boxed holds " << k.__value().id << "\n";
    }                                                       // ~Widget 9
    std::cout << "uniq\n";
    {
        Nullable<widgets::Uniq> u = widgets::Uniq(3);
        Nullable<widgets::Uniq> w = std::move(u);           // the payload moves; u still holds a (moved-from) Uniq
        std::cout << "u null " << u.is_null() << ", u id " << u.__value().id << ", w id " << w.__value().id << "\n";
        u = ::builtin::null;                                // the moved-from payload goes quietly
        std::cout << "u reset " << u.is_null() << "\n";
    }                                                       // ~Uniq 3, once
    std::cout << "done\n";
}
