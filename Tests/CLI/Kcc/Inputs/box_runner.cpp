#include "box.k"
#include <iostream>
#include <vector>
#include <string_view>

// 1. C++20 concept constraining a type that exposes a `.val` field
template <typename B>
concept HasVal = requires(const B& b) {
    { b.val };
};

// 2. C++ template function accepting any Kairo Box<T> satisfying the concept
template <HasVal B>
void inspect_box(const B& b) {
    std::cout << "Inspecting Box with val = " << b.val << "\n";
}

int main() {
    // Unbuffered: Kairo's println writes the fd directly, so a buffered
    // cout would print its lines after the destructor's.
    std::cout << std::unitbuf;
    // Generic C++ lambda calling Kairo's generic member template `combine<U>`
    auto combine_and_print = []<typename T, typename U>(box::Box<T>& b, U extra) {
        box::Combined<T, U> res = b.template combine<U>(extra);
        // C++17 structured binding over a generic Kairo struct!
        auto [first, second] = res;
        std::cout << "C++ lambda got Combined: {" << first << ", " << second << "}\n";
    };

    {
        // CTAD (Class Template Argument Deduction) on Kairo generic class
        box::Box intBox{42};
        inspect_box(intBox);
        combine_and_print(intBox, 3.14);

        // Storing Kairo generic structs inside a C++ std::vector
        std::vector<box::Combined<int, double>> results;
        results.push_back(intBox.combine<double>(100.5));
        results.push_back(intBox.combine<double>(200.75));

        for (const auto& [k_int, k_dbl] : results) {
            std::cout << "vec item: " << k_int << " | " << k_dbl << "\n";
        }
    } // intBox goes out of scope here -> triggers Box::~Box()

    return 0;
}
