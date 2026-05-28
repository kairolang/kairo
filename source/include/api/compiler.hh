/// --- The Kairo Project -------------------------------------------------- ///
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

#ifndef __COMPILER_HH__
#define __COMPILER_HH__

#include <string>
#include <vector>

namespace clang {
using namespace std;

struct Arguments {
    vector<string> args;  //> additional arguments to pass
    vector<string> libs;  //> lib dirs, such as for libcxx
    vector<string> incs;  //> include dirs
    vector<string> link;  //> link dirs
};

class Compiler {
  private:
    Arguments args;

  public:
    Compiler() = default;
    explicit Compiler(Arguments args);
};
}  // namespace clang

#endif  // __COMPILER_HH__