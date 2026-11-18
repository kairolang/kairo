// variant_main.cpp
#include "shapes2.k"
#include <variant>
#include <iostream>

template <class... F> struct overloaded : F... { using F::operator()...; };

int main() {
    std::cout << std::unitbuf;
    {
        std::variant<shapes2::Cat, shapes2::Dog> pet{std::in_place_type<shapes2::Cat>, 9};
        auto describe = overloaded{
            [](const shapes2::Cat& c) { std::cout << "cat with " << c.lives << " lives\n"; },
            [](const shapes2::Dog& d) { std::cout << "dog with " << d.tricks << " tricks\n"; },
        };
        std::visit(describe, pet);
        pet.emplace<shapes2::Dog>(3);   // should print ~Cat
        std::visit(describe, pet);
    }                                    // should print ~Dog
    std::cout << "done\n";
}