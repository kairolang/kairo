#pragma once

constexpr unsigned K_IN = 1u;
constexpr unsigned K_OUT = 4u;
constexpr long K_NEG = -5;
constexpr double K_HALF = 0.5;
constexpr int K_SIDE = 3;
struct Limits {
    static constexpr int MAX = 8;
};
constexpr int sq(int x) { return x * x; }

// Not constexpr: run-time values to Kairo.
const int K_CONST = 6;
inline unsigned K_MUT = 3;
extern const unsigned K_EXTERN;
struct Limits2 {
    static const int MIN = 2;
};
