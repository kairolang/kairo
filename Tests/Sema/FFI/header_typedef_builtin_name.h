#pragma once
typedef unsigned char Byte;
inline int one() { return 1; }
inline Byte low(Byte b) { return (Byte)(b & 0x0f); }
