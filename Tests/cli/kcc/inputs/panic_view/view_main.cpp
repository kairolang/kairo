// view_main.cpp: the C++ view of a Kairo panic result (PANIC.md §4.6): the
// inspection helpers, the panic_set trait, and value_or_throw with what().
#include "view.k"
#include <cstdio>

int main() {
    // The value API.
    auto r = view::load(5);
    std::printf("ok %d value %d\n", ::builtin::ok(r), ::builtin::value(r));
    auto e = view::load(0);
    std::printf("ok %d is<ConfigError> %d is<Plain> %d is<int> %d key %d\n", ::builtin::ok(e),
                ::builtin::is<view::ConfigError>(e), ::builtin::is<view::Plain>(e), ::builtin::is<int>(e),
                ::builtin::error<view::ConfigError>(e).key);
    auto s = ::builtin::site(e);
    std::printf("site %s:%u:%u\n", s.file, s.line, s.col);
    std::printf("ok has no site %d\n", ::builtin::site(r).file == nullptr);
    using S = ::builtin::panic_set<decltype(e)>;
    std::printf("set size %u offset %u tag is id %d\n", S::size, S::payload_offset,
                static_cast<unsigned>(e.__kairo_tag) == ::builtin::type_id<view::ConfigError>);
    std::printf("value_type int %d\n", __is_same(S::value_type, int));

    // value_or_throw: the value, or panic_error<E> for the E it holds.
    std::printf("value_or_throw %d\n", ::builtin::value_or_throw(view::load(4)));
    try { ::builtin::value_or_throw(view::load(0)); }
    catch (const ::builtin::panic_error<view::ConfigError>& x) {
        std::printf("ConfigError key %d type %d what: %s\n", x.error.key, x.type == ::builtin::type_id<view::ConfigError>, x.what());
    }
    try { ::builtin::value_or_throw(view::load(1)); }
    catch (const ::builtin::panic_error_base& x) { std::printf("base what: %s\n", x.what()); }
    try { ::builtin::value_or_throw(view::load(3)); }
    catch (const std::exception& x) { std::printf("std what: %s\n", x.what()); }
    // An lvalue result is copied out, and stays as it was.
    try { ::builtin::value_or_throw(e); }
    catch (const ::builtin::panic_error<view::ConfigError>& x) { std::printf("lvalue key %d still %d\n", x.error.key, ::builtin::error<view::ConfigError>(e).key); }
    // A void result.
    ::builtin::value_or_throw(view::check(1));
    try { ::builtin::value_or_throw(view::check(-2)); }
    catch (const ::builtin::panic_error<view::Plain>& x) { std::printf("void n %d what: %s\n", x.error.n, x.what()); }
    // A move-only error, moved into the exception; copies of the exception
    // share one what() buffer.
    try { ::builtin::value_or_throw(view::big(-4)); }
    catch (::builtin::panic_error_base& x) {
        ::builtin::panic_error_base copy = x;
        auto* b = dynamic_cast< ::builtin::panic_error<view::Big>* >(&x);
        std::printf("big %d same text %d what: %s\n", b ? b->error.get() : 0, copy.what() == x.what(), copy.what());
    }
    return 0;
}
