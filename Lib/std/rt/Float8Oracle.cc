//===--- Float8Oracle.cc -------------------------------------------------===//
// Differential test: our Float8.hh against APFloat's semFloat8E4M3FN /
// semFloat8E5M2. Exhaustive over all 256 encodings, both directions.
#include "Float8.hh"
#include "llvm/ADT/APFloat.h"
#include "llvm/ADT/APInt.h"
#include <cstdio>
#include <cmath>

using namespace kairo::rt;
using llvm::APFloat;
using llvm::APInt;

template <typename T>
static int check(const char *name, const llvm::fltSemantics &sem) {
    int bad = 0;
    for (unsigned i = 0; i < 256; ++i) {
        T mine;
        mine.bits = static_cast<std::uint8_t>(i);

        APFloat ref(sem, APInt(8, i));

        // Direction 1: fp8 -> f32.
        float mine_f = mine.to_f32();
        float ref_f  = ref.convertToFloat();
        if (mine.is_nan()) {
            if (!std::isnan(mine_f) || !ref.isNaN()) {
                std::printf("%s 0x%02X: NaN disagreement\n", name, i);
                ++bad;
            }
            continue;
        }
        if (f32_bits(mine_f) != f32_bits(ref_f)) {
            std::printf("%s 0x%02X: to_f32 %g vs APFloat %g\n",
                        name, i, double(mine_f), double(ref_f));
            ++bad;
        }

        // Direction 2: f32 -> fp8, on the value APFloat produced.
        APFloat rt(ref_f);
        bool lost;
        rt.convert(sem, APFloat::rmNearestTiesToEven, &lost);
        auto ref_bits = static_cast<std::uint8_t>(
            rt.bitcastToAPInt().getZExtValue());
        T back(ref_f);
        if (back.bits != ref_bits) {
            std::printf("%s 0x%02X: from_f32 0x%02X vs APFloat 0x%02X\n",
                        name, i, back.bits, ref_bits);
            ++bad;
        }
    }
    std::printf("%-6s %s\n", name, bad ? "FAIL" : "ok");
    return bad;
}

int main() {
    int bad = 0;
    bad += check<f8e4m3>("e4m3", APFloat::Float8E4M3FN());
    bad += check<f8e5m2>("e5m2", APFloat::Float8E5M2());
    return bad != 0;
}