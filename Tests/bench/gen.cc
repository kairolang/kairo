#include <coroutine>
#include <iterator>
#include <cstdio>
#include <cstdlib>
#include <utility>

template <class T> struct Generator {
    struct promise_type {
        T value;
        Generator get_return_object() { return Generator{std::coroutine_handle<promise_type>::from_promise(*this)}; }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        std::suspend_always yield_value(T v) noexcept { value = v; return {}; }
        void return_void() noexcept {}
        void unhandled_exception() { std::abort(); }
    };
    struct iterator {
        std::coroutine_handle<promise_type> h;
        iterator& operator++() { h.resume(); return *this; }
        T operator*() const { return h.promise().value; }
        bool operator!=(std::default_sentinel_t) const { return !h.done(); }
    };
    explicit Generator(std::coroutine_handle<promise_type> h) : h(h) {}
    Generator(Generator&& o) noexcept : h(std::exchange(o.h, {})) {}
    ~Generator() { if (h) h.destroy(); }
    iterator begin() { h.resume(); return {h}; }
    std::default_sentinel_t end() { return {}; }
    std::coroutine_handle<promise_type> h;
};

Generator<long> upto(long n) { for (long i = 0; i < n; ++i) co_yield i; }
Generator<long> squares(long n) { for (long v : upto(n)) co_yield v * v % 1000003; }
Generator<long> evens(long n) { for (long v : squares(n)) if (v % 2 == 0) co_yield v; }

int main() {
    long n = std::atol(std::getenv("N"));
    long sum = 0;
    for (long v : evens(n)) sum += v;
    std::printf("%ld\n", sum);
}
