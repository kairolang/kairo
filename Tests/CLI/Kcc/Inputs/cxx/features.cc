#include <algorithm>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <typeinfo>
#include <unordered_map>
#include <variant>
#include <vector>

struct Base { virtual ~Base() = default; virtual int f() const { return 1; } };
struct Derived : Base { int f() const override { return 2; } };

template <class T> constexpr T square(T x) { return x * x; }
static_assert(square(7) == 49);

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    // exceptions
    try { throw std::runtime_error("boom"); }
    catch (const std::exception& e) { std::printf("caught %s\n", e.what()); }
    // RTTI
    std::unique_ptr<Base> p = std::make_unique<Derived>();
    std::printf("dyn %d virt %d\n", dynamic_cast<Derived*>(p.get()) != nullptr, p->f());
    const Base& ref = *p;
    std::printf("typeid %d\n", typeid(ref) == typeid(Derived));
    // containers and algorithms
    std::vector<int> v{5, 3, 9, 1};
    std::sort(v.begin(), v.end());
    std::map<std::string, int> m{{"b", 2}, {"a", 1}};
    std::unordered_map<int, std::string> u{{1, "one"}};
    std::printf("sorted %d %d %d %d first %s=%d u %s\n", v[0], v[1], v[2], v[3],
                m.begin()->first.c_str(), m.begin()->second, u[1].c_str());
    // lambdas, std::function, optional, variant
    std::function<int(int)> twice = [](int x) { return x * 2; };
    std::optional<int> o = 4;
    std::variant<int, std::string> var = std::string("str");
    std::printf("fn %d opt %d var %s\n", twice(21), *o, std::get<std::string>(var).c_str());
    return 0;
}
