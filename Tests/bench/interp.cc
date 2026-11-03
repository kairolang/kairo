// See interp.k. A tagged instruction struct and a switch: the usual C++
// interpreter loop.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

enum class Op : uint8_t { LoadI, Mul, ModI, Add, AddI, JmpLt, Halt };
struct Inst { Op op; int a, b, c; int64_t v; };

void run(const std::array<Inst, 9>& prog, std::array<int64_t, 8>& r) {
    int pc = 0;
    for (;;) {
        const Inst& i = prog[pc];
        switch (i.op) {
            case Op::LoadI: r[i.a] = i.v; ++pc; break;
            case Op::Mul:   r[i.a] = r[i.b] * r[i.c]; ++pc; break;
            case Op::ModI:  r[i.a] = r[i.b] % i.v; ++pc; break;
            case Op::Add:   r[i.a] = r[i.b] + r[i.c]; ++pc; break;
            case Op::AddI:  r[i.a] += i.v; ++pc; break;
            case Op::JmpLt: pc = r[i.a] < r[i.b] ? i.c : pc + 1; break;
            case Op::Halt:  return;
        }
    }
}

int main() {
    int64_t n = std::atoll(std::getenv("N"));
    std::array<Inst, 9> prog{{
        {Op::LoadI, 0, 0, 0, 0},  {Op::LoadI, 1, 0, 0, 0},  {Op::LoadI, 2, 0, 0, n},
        {Op::Mul, 3, 0, 0, 0},    {Op::ModI, 3, 3, 0, 7},   {Op::Add, 1, 1, 3, 0},
        {Op::AddI, 0, 0, 0, 1},   {Op::JmpLt, 0, 2, 3, 0},  {Op::Halt, 0, 0, 0, 0},
    }};
    std::array<int64_t, 8> regs{};
    run(prog, regs);
    std::printf("%lld\n", (long long)regs[1]);
}
