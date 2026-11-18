#pragma once

// Kairo maps C integers by width, so one Kairo integer can be EXACT against
// two C types: on LLP64 `long` is i32 like `int`; on LP64 `long long` is i64
// like `long`. C++ treats only the target's own spelling as identity.

int  pick(int);
bool pick(long);         // LLP64: ties with pick(int) for an i32; must lose.

long      wide(long);
long long wide(long long);  // LP64: ties with wide(long) for an i64; must lose.
