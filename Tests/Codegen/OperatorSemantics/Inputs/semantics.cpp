// The wrap forms EmitIR spells (Codegen/Emit/EmitIR.k, "the wrap forms"),
// copied verbatim and constant-evaluated: each static_assert proves the value
// AND the absence of UB, since a constant expression may not overflow.
extern "C" [[noreturn, gnu::cold]] void kairo_rt_div_zero() noexcept;
constexpr unsigned short mul16(unsigned short a, unsigned short b) { return static_cast<unsigned short>(static_cast<unsigned>(a) * static_cast<unsigned>(b)); }
constexpr signed char add8(signed char a, signed char b) { return static_cast<signed char>(static_cast<unsigned>(a) + static_cast<unsigned>(b)); }
constexpr int div32(int a, int b) { return ({ int __kairo_a0 = a; int __kairo_b0 = b; if (__builtin_expect(__kairo_b0 == 0, 0)) kairo_rt_div_zero(); (__kairo_b0 == -1) ? static_cast<int>(static_cast<unsigned>(0) - static_cast<unsigned>(__kairo_a0)) : static_cast<int>(__kairo_a0 / __kairo_b0); }); }
constexpr int rem32(int a, int b) { return ({ int __kairo_a0 = a; int __kairo_b0 = b; if (__builtin_expect(__kairo_b0 == 0, 0)) kairo_rt_div_zero(); (__kairo_b0 == -1) ? 0 : static_cast<int>(__kairo_a0 % __kairo_b0); }); }
constexpr int shl32(int a, int b) { return static_cast<int>(static_cast<unsigned>(a) << (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
// Shifts (SHIFT spec §3.1): the count modulo R, the register width (32
// below 32 bits), so a narrow type masks by 31, not W - 1; a signed `>>`
// sign-extends to R_T first.
constexpr signed char shl8(signed char a, int b) { return static_cast<signed char>(static_cast<unsigned>(a) << (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
constexpr unsigned char ushl8(unsigned char a, int b) { return static_cast<unsigned char>(static_cast<unsigned>(a) << (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
constexpr unsigned char ushr8(unsigned char a, int b) { return static_cast<unsigned char>(static_cast<unsigned>(a) >> (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
constexpr signed char shr8(signed char a, int b) { return static_cast<signed char>(static_cast<int>(a) >> (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
constexpr int shr32(int a, int b) { return static_cast<int>(static_cast<int>(a) >> (static_cast<unsigned>(b) & static_cast<unsigned>(31))); }
constexpr long long shr64(long long a, int b) { return static_cast<long long>(static_cast<long long>(a) >> (static_cast<unsigned long long>(b) & static_cast<unsigned long long>(63))); }
// no_wrap (§4): a count proven in [0, W), unmasked.
constexpr unsigned char nw_shl8(unsigned char a, int b) { return static_cast<unsigned char>(static_cast<unsigned>(a) << static_cast<unsigned>(b)); }
// A duck generic's shift (§3.3), the integer arm per instance.
template <class T> constexpr T dep_shr(T a, int b) {
    return [&]() {
        using __kairo_T0 = __remove_cvref(decltype(a));
        if constexpr (__is_integral(__kairo_T0) && (!__is_same(__kairo_T0, bool))) {
            using __kairo_U0 = decltype(static_cast<__make_unsigned(__kairo_T0)>(0) + 0u);
            constexpr auto __kairo_R0 = (sizeof(__kairo_T0) * 8 > 64) ? 128 : ((sizeof(__kairo_T0) * 8 < 32) ? 32 : sizeof(__kairo_T0) * 8);
            if constexpr (__is_signed(__kairo_T0)) { using __kairo_S0 = __make_signed(__kairo_U0); return static_cast<__kairo_T0>(static_cast<__kairo_S0>(a) >> (static_cast<__kairo_U0>(b) & static_cast<__kairo_U0>(__kairo_R0 - 1))); }
            return static_cast<__kairo_T0>(static_cast<__kairo_U0>(a) >> (static_cast<__kairo_U0>(b) & static_cast<__kairo_U0>(__kairo_R0 - 1)));
        } else { return a >> b; } }();
}
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
static_assert(shl8(1, 9) == 0);          // every bit leaves the byte
static_assert(ushl8(1, 9) == 0);
static_assert(ushl8(1, 33) == 2);        // 33 mod 32
static_assert(ushl8(0x81, -1) == 0);     // -1 is 0xFFFFFFFF: mod 32 is 31
static_assert(ushr8(0x81, 7) == 1);
static_assert(ushr8(0x81, 9) == 0);
static_assert(shr8(-127, 9) == -1);      // sign fill past the byte
static_assert(shr8(-127, 33) == -64);    // 33 mod 32 is 1
static_assert(shr32(-8, 1) == -4);
static_assert(shr32(-8, 33) == -4);
static_assert(shr64(-8, 65) == -4);
static_assert(nw_shl8(3, 7) == 128);
static_assert(dep_shr<signed char>(-127, 9) == -1);
static_assert(dep_shr<unsigned char>(0x81, 9) == 0);
static_assert(dep_shr<unsigned short>(0x81, 33) == 0x40);
static_assert(dep_shr<long long>(-8, 65) == -4);
static_assert(bnot8(0) == 255);
static_assert(neg64(-9223372036854775807LL - 1) == -9223372036854775807LL - 1);
static_assert(inc_place() == -2147483647 - 1);
static_assert(ns_div == 3);

#ifdef BAD
constexpr int z = div32(1, 0); // expected-error {{constexpr variable 'z' must be initialized by a constant expression}} expected-note@* {{non-constexpr function 'kairo_rt_div_zero'}} expected-note@* {{in call to}} expected-note@* {{declared here}}
#endif
