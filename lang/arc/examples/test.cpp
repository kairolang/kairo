#include <concepts>
#include <coroutine>
#include <iostream>
#include <optional>
#include <ranges>
#include <string>
#include <vector>

// Global variable
inline int globalVar = 42;

// C-style struct
struct CStyleStruct {
    int a;
    double b;
};

// C++ style struct
struct CPPStyleStruct {
    int a;
    double b;
    std::string toString() const { return "a: " + std::to_string(a) + ", b: " + std::to_string(b); }
};

// Template function
template <typename T>
inline T add(T a, T b) {
    return a + b;
}

// Concept (C++20)
template <typename T>
concept Arithmetic = std::integral<T> || std::floating_point<T>;

// Template class
template <Arithmetic T>
class Calculator {
  public:
    T add(T a, T b) { return a + b; }
    T subtract(T a, T b) { return a - b; }
};

// Class with member variables and functions
class MyClass {
  public:
    MyClass(int val)
        : value(val) {}

    void setValue(int val) { value = val; }
    int getValue() const { return value; }

  private:
    int value;
};

// Closure (Lambda function)
inline auto createClosure(int x) {
    return [=](int y) { return x + y; };
}

// Coroutine (C++20)
struct Generator {
    struct promise_type {
        int current_value;
        std::suspend_always yield_value(int value) {
            current_value = value;
            return {};
        }
        std::suspend_always initial_suspend() { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        Generator get_return_object() { return Generator{}; }
        void return_void() {}
        void unhandled_exception() { std::exit(1); }
    };

    struct iterator {
        std::coroutine_handle<promise_type> coro;
        bool operator!=(const iterator &other) const { return !coro.done(); }
        iterator &operator++() {
            coro.resume();
            return *this;
        }
        int operator*() const { return coro.promise().current_value; }
    };

    iterator begin() { return iterator{handle}; }
    iterator end() { return iterator{nullptr}; }

    std::coroutine_handle<promise_type> handle;
};

inline Generator sequence(int start, int step) {
    for (int i = start;; i += step) {
        co_yield i;
    }
}
