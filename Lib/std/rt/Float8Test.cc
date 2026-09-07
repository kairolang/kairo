//===--- Float8Test.cc ---------------------------------------------------===//
#include "Float8.hh"
#include <cstdio>

using namespace kairo::rt;

int main() {
    struct { const char *name; bool ok; } t[] = {
        {"e4m3 roundtrip", verify_e4m3_roundtrip()},
        {"e5m2 roundtrip", verify_e5m2_roundtrip()},
        {"e4m3 known",     verify_e4m3_known()},
        {"e5m2 known",     verify_e5m2_known()},
    };

    int failed = 0;
    for (auto &c : t) {
        std::printf("%-16s %s\n", c.name, c.ok ? "ok" : "FAIL");
        if (!c.ok) { ++failed; }
    }

    // Dump the full E4M3FN table when anything fails -- the pattern of wrong
    // entries localizes the bug faster than any single assertion. All-zero
    // above the normal threshold means a bias error; wrong only near 0x00-0x07
    // means the subnormal path.
    if (failed) {
        std::printf("\nE4M3FN table:\n");
        for (std::uint32_t i = 0; i < 256; ++i) {
            f8e4m3 a;
            a.bits = static_cast<std::uint8_t>(i);
            f8e4m3 b(a.to_f32());
            std::printf("  0x%02X -> %-14g -> 0x%02X %s\n",
                        i, static_cast<double>(a.to_f32()), b.bits,
                        (b.bits == a.bits || a.is_nan()) ? "" : "  <-- MISMATCH");
        }
    }
    return failed;
}