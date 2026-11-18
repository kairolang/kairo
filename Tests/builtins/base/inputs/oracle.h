#pragma once
// The C++ standard library's conversions, as plain functions on byte
// buffers: the reference the differential tests compare against.
#include <charconv>
#include <cstdint>
#include <cstring>
#include <system_error>

// Each writer returns the number of bytes written to out.
inline int oracle_u64_text(uint64_t v, unsigned char *out) {
    char *b = reinterpret_cast<char *>(out);
    return static_cast<int>(std::to_chars(b, b + 64, v).ptr - b);
}
inline int oracle_i64_text(int64_t v, unsigned char *out) {
    char *b = reinterpret_cast<char *>(out);
    return static_cast<int>(std::to_chars(b, b + 64, v).ptr - b);
}
// Shortest round-trip digits in scientific form: d[.ddd]e[+-]XX.
inline int oracle_f64_sci(double v, unsigned char *out) {
    char *b = reinterpret_cast<char *>(out);
    return static_cast<int>(std::to_chars(b, b + 64, v, std::chars_format::scientific).ptr - b);
}
inline int oracle_f32_sci(float v, unsigned char *out) {
    char *b = reinterpret_cast<char *>(out);
    return static_cast<int>(std::to_chars(b, b + 64, v, std::chars_format::scientific).ptr - b);
}

// Each reader returns 0 when a number was matched and is in range, 1 when
// text[0..n) does not start with a number, 2 when a number was matched but
// is out of range. *consumed is the number of bytes the number occupies,
// which is less than n when other bytes follow it.
template <class T> inline int oracle_from(const unsigned char *text, size_t n, T *out, size_t *consumed) {
    const char *b = reinterpret_cast<const char *>(text);
    auto r = std::from_chars(b, b + n, *out);
    *consumed = static_cast<size_t>(r.ptr - b);
    if (r.ec == std::errc::result_out_of_range) return 2;
    if (r.ec != std::errc()) return 1;
    return 0;
}
inline int oracle_u64_from(const unsigned char *t, size_t n, uint64_t *out, size_t *c) { return oracle_from(t, n, out, c); }
inline int oracle_i64_from(const unsigned char *t, size_t n, int64_t *out, size_t *c) { return oracle_from(t, n, out, c); }
inline int oracle_f64_from(const unsigned char *t, size_t n, double *out, size_t *c) { return oracle_from(t, n, out, c); }
inline int oracle_f32_from(const unsigned char *t, size_t n, float *out, size_t *c) { return oracle_from(t, n, out, c); }
