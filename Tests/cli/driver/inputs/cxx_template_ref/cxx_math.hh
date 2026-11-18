#pragma once
#include <iostream>
#include <cstddef>

// C++20 Concept that will constrain a Kairo generic class!
template <typename B>
concept IndexableBuffer = requires(B& b, const B& cb, std::size_t i) {
    { cb.len() } -> std::convertible_to<std::size_t>;
    { b[i] };
    { cb[i] };
};

// C++ template function mutating a Kairo object through its `op []` place operator
template <IndexableBuffer B, typename T>
T cxx_scale_and_sum(B& buf, T factor) {
    T total = 0;
    for (std::size_t i = 0; i < buf.len(); ++i) {
        buf[i] = buf[i] * factor; // writes through Kairo's `fn op [](self) -> *T`!
        total += buf[i];
    }
    return total;
}

class CxxAccumulator {
    int last_val = 0;
    int total = 0;
public:
    CxxAccumulator() = default;

    void feed(const int& x) {
        std::cout << "  [C++] feed(const int& lvalue) = " << x << "\n";
        last_val = x;
        total += x;
    }

    void feed(int&& x) {
        std::cout << "  [C++] feed(int&& rvalue)      = " << x << "\n";
        last_val = x;
        total += x * 10;
    }

    // Returns C++ lvalue reference `int&` -> Kairo sees `*i32` place!
    int& last_mut() { return last_val; }
    int get_total() const { return total + last_val; }
};