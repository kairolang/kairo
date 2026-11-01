// The wrap forms EmitIR spells (Codegen/Emit/EmitIR.k, "the wrap forms"),
// copied verbatim and constant-evaluated: each static_assert proves the value
// AND the absence of UB, since a constant expression may not overflow.
extern "C" [[noreturn, gnu::cold]] void kairo_rt_div_zero() noexcept;
constexpr unsigned short mul16(unsigned short a, unsigned short b) { return static_cast<unsigned short>(static_cast<unsigned>(a) * static_cast<unsigned>(b)); }
constexpr signed char add8(signed char a, signed char b) { return static_cast<signed char>(static_cast<unsigned>(a) + static_cast<unsigned>(b)); }
constexpr int div32(int a, int b) { return ({ int __kairo_a0 = a; int __kairo_b0 = b; if (__builtin_expect(__kairo_b0 == 0, 0)) kairo_rt_div_zero(); (__kairo_b0 == -1) ? static_cast<int>(static_cast<unsigned>(0) - static_cast<unsigned>(__kairo_a0)) : static_cast<int>(__kairo_a0 / __kairo_b0); }); }
constexpr int rem32(int a, int b) { return ({ int __kairo_a0 = a; int __kairo_b0 = b; if (__builtin_expect(__kairo_b0 == 0, 0)) kairo_rt_div_zero(); (__kairo_b0 == -1) ? 0 : static_cast<int>(__kairo_a0 % __kairo_b0); }); }
constexpr int shl32(int a, int b) { return static_cast<int>(static_cast<unsigned>(a) << (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
constexpr signed char shl8(signed char a, signed char b) { return static_cast<signed char>(static_cast<unsigned>(a) << (static_cast<unsigned>(b) & static_cast<unsigned>(7))); }
constexpr int shr32(int a, int b) { return static_cast<int>((a) >> (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
constexpr unsigned char bnot8(unsigned char a) { return static_cast<unsigned char>(~static_cast<unsigned>(a)); }
constexpr long long neg64(long long a) { return static_cast<long long>(static_cast<unsigned long long>(0) - static_cast<unsigned long long>(a)); }
constexpr int inc_place() { int i = 2147483647; int* p = &i; ({ auto& __kairo_p0 = *p; __kairo_p0 = static_cast<int>(static_cast<unsigned>(__kairo_p0) + static_cast<unsigned>(1)); }); return i; }
// A namespace-scope binding form is a capture-less lambda called on the spot.
inline constexpr int ns_div = []() { int __kairo_a0 = (7); int __kairo_b0 = (2); if (__builtin_expect(__kairo_b0 == 0, 0)) ::kairo_rt_div_zero(); return (__kairo_b0 == -1) ? static_cast<int>(static_cast<unsigned>(0) - static_cast<unsigned>(__kairo_a0)) : static_cast<int>(__kairo_a0 / __kairo_b0); }();

static_assert(mul16(65535, 65535) == 1);
static_assert(add8(127, 1) == -128);
static_assert(div32(-2147483647 - 1, -1) == -2147483647 - 1);
static_assert(div32(7, 2) == 3);
static_assert(rem32(-2147483647 - 1, -1) == 0);
static_assert(shl32(1, 33) == 2);
static_assert(shl8(1, 7) == -128);
static_assert(shr32(-8, 1) == -4);
static_assert(bnot8(0) == 255);
static_assert(neg64(-9223372036854775807LL - 1) == -9223372036854775807LL - 1);
static_assert(inc_place() == -2147483647 - 1);
static_assert(ns_div == 3);

#ifdef BAD
constexpr int z = div32(1, 0); // expected-error {{constexpr variable 'z' must be initialized by a constant expression}} expected-note@* {{non-constexpr function 'kairo_rt_div_zero'}} expected-note@* {{in call to}} expected-note@* {{declared here}}
#endif
