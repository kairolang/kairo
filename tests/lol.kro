fn main() -> i32 {
    fn this_is_a_lambda() -> i32 {
        print("uess");
        return 12;
    }

    print(f"lamb = {this_is_a_lambda()},\n loc = {&this_is_a_lambda}");
    return 0;
}

// kairo ir
auto main() -> i32 {
    auto this_is_a_lambda = []() -> i32 {
        print(string("uess"));
        return i32(12);
    };

    print(kairo::std::stringf(string("lamb = \\{\\}\n, loc = \\{\\}"), (this_is_a_lambda()), ((&(this_is_a_lambda)))));
    return i32(0);
}

// actual c++
#include "iostream"

auto main() -> int {
    auto this_is_a_lambda = []() -> int {
        std::cout << "uess";
        return 12;
    };

    std::cout << "lamb = " << std::to_string(this_is_a_lambda()) << "\n, loc = " << std::to_string(&(this_is_a_lambda));
    return 0;
}
