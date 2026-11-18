// Corpus for enum.k: an unscoped enum (enumerators visible in the enclosing
// scope too) and a scoped one with an explicit underlying type.
#pragma once

enum Color { Red, Green, Blue };

enum class Mode : unsigned char { Fast, Slow };

Color favorite();
