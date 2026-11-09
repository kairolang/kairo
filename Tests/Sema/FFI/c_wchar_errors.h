// c_wchar_errors.k's C++ side: overloads that only the character types tell
// apart from the integers of their width.
#pragma once
inline int pick(wchar_t) { return 1; }
inline int pick(int) { return 2; }
inline int takes16(char16_t) { return 1; }
