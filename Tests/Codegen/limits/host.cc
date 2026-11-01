// C++ oracle for limits_lib.k: every Kairo limit equals clang's own
// predefined macro, at compile time (the bindings are constant
// expressions through `#include "*.k"`, EVAL.md 1.2b).
#include "limits_lib.k"

#define K ::limits_lib::
static_assert(K I8_MIN == -__INT8_MAX__ - 1 && K I8_MAX == __INT8_MAX__);
static_assert(K I8_BITS == 8);
static_assert(K I16_MIN == -__INT16_MAX__ - 1 && K I16_MAX == __INT16_MAX__);
static_assert(K I16_BITS == 16);
static_assert(K I32_MIN == -__INT32_MAX__ - 1 && K I32_MAX == __INT32_MAX__);
static_assert(K I32_BITS == 32);
static_assert(K I64_MIN == -__INT64_MAX__ - 1 && K I64_MAX == __INT64_MAX__);
static_assert(K I64_BITS == 64);
static_assert(K U8_MIN == 0 && K U8_MAX == __UINT8_MAX__);
static_assert(K U8_BITS == 8);
static_assert(K U16_MIN == 0 && K U16_MAX == __UINT16_MAX__);
static_assert(K U16_BITS == 16);
static_assert(K U32_MIN == 0 && K U32_MAX == __UINT32_MAX__);
static_assert(K U32_BITS == 32);
static_assert(K U64_MIN == 0 && K U64_MAX == __UINT64_MAX__);
static_assert(K U64_BITS == 64);
static_assert(K I128_MAX == static_cast<__int128>((static_cast<unsigned __int128>(1) << 127) - 1));
static_assert(K I128_MIN == -K I128_MAX - 1 && K U128_MIN == 0);
static_assert(K U128_MAX == ~static_cast<unsigned __int128>(0) && K I128_BITS == 128 && K U128_BITS == 128);
static_assert(K USIZE_MAX == __SIZE_MAX__ && K USIZE_MIN == 0 && K USIZE_BITS == __SIZEOF_POINTER__ * 8);
static_assert(K ISIZE_MAX == __PTRDIFF_MAX__ && K ISIZE_MIN == -__PTRDIFF_MAX__ - 1 && K ISIZE_BITS == __SIZEOF_POINTER__ * 8);
static_assert(K CHAR_MAX == U'\U0010FFFF' && K CHAR_BITS == 32 && K BYTE_BITS == 8 && K U512_BITS == 512);
// f16
static_assert(K F16_MAX == __FLT16_MAX__ && K F16_MIN == -__FLT16_MAX__);
static_assert(K F16_MIN_POSITIVE == __FLT16_MIN__ && K F16_MIN_SUBNORMAL == __FLT16_DENORM_MIN__);
static_assert(K F16_EPSILON == __FLT16_EPSILON__);
static_assert(__builtin_isinf(K F16_INFINITY) && K F16_INFINITY > 0 && __builtin_isinf(K F16_NEG_INFINITY) && K F16_NEG_INFINITY < 0);
static_assert(K F16_NAN != K F16_NAN);
static_assert(K F16_MANTISSA_DIGITS == __FLT16_MANT_DIG__ && K F16_DIGITS == __FLT16_DIG__ && K F16_MAX_DIGITS == __FLT16_DECIMAL_DIG__);
static_assert(K F16_MIN_EXP == __FLT16_MIN_EXP__ && K F16_MAX_EXP == __FLT16_MAX_EXP__);
static_assert(K F16_MIN_10_EXP == __FLT16_MIN_10_EXP__ && K F16_MAX_10_EXP == __FLT16_MAX_10_EXP__);
static_assert(K F16_RADIX == 2 && K F16_BITS == sizeof(_Float16) * 8);
// f32
static_assert(K F32_MAX == __FLT_MAX__ && K F32_MIN == -__FLT_MAX__);
static_assert(K F32_MIN_POSITIVE == __FLT_MIN__ && K F32_MIN_SUBNORMAL == __FLT_DENORM_MIN__);
static_assert(K F32_EPSILON == __FLT_EPSILON__);
static_assert(__builtin_isinf(K F32_INFINITY) && K F32_INFINITY > 0 && __builtin_isinf(K F32_NEG_INFINITY) && K F32_NEG_INFINITY < 0);
static_assert(K F32_NAN != K F32_NAN);
static_assert(K F32_MANTISSA_DIGITS == __FLT_MANT_DIG__ && K F32_DIGITS == __FLT_DIG__ && K F32_MAX_DIGITS == __FLT_DECIMAL_DIG__);
static_assert(K F32_MIN_EXP == __FLT_MIN_EXP__ && K F32_MAX_EXP == __FLT_MAX_EXP__);
static_assert(K F32_MIN_10_EXP == __FLT_MIN_10_EXP__ && K F32_MAX_10_EXP == __FLT_MAX_10_EXP__);
static_assert(K F32_RADIX == 2 && K F32_BITS == sizeof(float) * 8);
// f64
static_assert(K F64_MAX == __DBL_MAX__ && K F64_MIN == -__DBL_MAX__);
static_assert(K F64_MIN_POSITIVE == __DBL_MIN__ && K F64_MIN_SUBNORMAL == __DBL_DENORM_MIN__);
static_assert(K F64_EPSILON == __DBL_EPSILON__);
static_assert(__builtin_isinf(K F64_INFINITY) && K F64_INFINITY > 0 && __builtin_isinf(K F64_NEG_INFINITY) && K F64_NEG_INFINITY < 0);
static_assert(K F64_NAN != K F64_NAN);
static_assert(K F64_MANTISSA_DIGITS == __DBL_MANT_DIG__ && K F64_DIGITS == __DBL_DIG__ && K F64_MAX_DIGITS == __DBL_DECIMAL_DIG__);
static_assert(K F64_MIN_EXP == __DBL_MIN_EXP__ && K F64_MAX_EXP == __DBL_MAX_EXP__);
static_assert(K F64_MIN_10_EXP == __DBL_MIN_10_EXP__ && K F64_MAX_10_EXP == __DBL_MAX_10_EXP__);
static_assert(K F64_RADIX == 2 && K F64_BITS == sizeof(double) * 8);
// f80
static_assert(K F80_MAX == __LDBL_MAX__ && K F80_MIN == -__LDBL_MAX__);
static_assert(K F80_MIN_POSITIVE == __LDBL_MIN__ && K F80_MIN_SUBNORMAL == __LDBL_DENORM_MIN__);
static_assert(K F80_EPSILON == __LDBL_EPSILON__);
static_assert(__builtin_isinf(K F80_INFINITY) && K F80_INFINITY > 0 && __builtin_isinf(K F80_NEG_INFINITY) && K F80_NEG_INFINITY < 0);
static_assert(K F80_NAN != K F80_NAN);
static_assert(K F80_MANTISSA_DIGITS == __LDBL_MANT_DIG__ && K F80_DIGITS == __LDBL_DIG__ && K F80_MAX_DIGITS == __LDBL_DECIMAL_DIG__);
static_assert(K F80_MIN_EXP == __LDBL_MIN_EXP__ && K F80_MAX_EXP == __LDBL_MAX_EXP__);
static_assert(K F80_MIN_10_EXP == __LDBL_MIN_10_EXP__ && K F80_MAX_10_EXP == __LDBL_MAX_10_EXP__);
static_assert(K F80_RADIX == 2 && K F80_BITS == sizeof(long double) * 8);

int main() { return 42; }
