// C++ that hands Kairo wchar_t, char16_t and char8_t. Imported by
// wide_chars.k: each is its own C++ type, so `pick` and friends are
// overloads that an integer of the same width does not collapse.
#pragma once
#include <cstddef>
#include <string>
#include <vector>

inline int code_w(wchar_t c) { return (int)c; }
inline int code_16(char16_t c) { return (int)c; }
inline int code_8(char8_t c) { return (int)c; }

inline int pick(wchar_t) { return 1; }
inline int pick(int) { return 2; }
inline int pick(unsigned int) { return 3; }
inline int pick16(char16_t) { return 1; }
inline int pick16(unsigned short) { return 2; }
inline int pick8(char8_t) { return 1; }
inline int pick8(unsigned char) { return 2; }

inline wchar_t wide_a() { return L'A'; }
inline std::wstring make_wide() { return L"wide"; }
inline std::u16string make_u16() { return u"utf16"; }
inline std::size_t wlen(const std::wstring &s) { return s.size(); }
inline std::size_t u16len(const std::u16string &s) { return s.size(); }
inline std::size_t wcount(const wchar_t *s) {
    std::size_t n = 0;
    while (s[n]) { ++n; }
    return n;
}
inline std::size_t wvec_size(const std::vector<wchar_t> &v) { return v.size(); }
