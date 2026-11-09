//===-- Native/TokenArray.hh - clang::Token[] for Kairo ----------------------===//
//
// Kairo's `[T;]` is a slice, so an unbounded C++ array type is named through
// an alias (make_unique<TokenArray>(n)). EnterTokenStream takes the
// unique_ptr<Token[]> and frees it.
//
//===----------------------------------------------------------------------===//
#pragma once
#include "clang/Lex/Token.h"
#include <memory>

namespace kairo {
using TokenArray = clang::Token[];
}
