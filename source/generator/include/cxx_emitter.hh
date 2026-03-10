//===------------------------------------------ C++ ------------------------------------------====//
//                                                                                                //
//  Part of the Kairo Project, under the Attribution 4.0 International license (CC BY 4.0).       //
//  You are allowed to use, modify, redistribute, and create derivative works, even for           //
//  commercial purposes, provided that you give appropriate credit, and indicate if changes       //
//   were made. For more information, please visit: https://creativecommons.org/licenses/by/4.0/  //
//                                                                                                //
//  SPDX-License-Identifier: Apache-2.0                                                           //
//  Copyright (c) 2024 (CC BY 4.0)                                                                //
//                                                                                                //
//====----------------------------------------------------------------------------------------====//
//                                                                                                //
//  This file defines the CXXGenerator class, which is used to convert the AST to JSON.         //
//  The JSON representation of the AST is used for debugging and testing purposes.                //
//                                                                                                //
//===-----------------------------------------------------------------------------------------====//

#ifndef __CXX_EMITTER_HH__
#define __CXX_EMITTER_HH__

#include "parser/ast/include/types/AST_visitor.hh"

namespace codegen::cxx {
enum class GenerateMode {
    GENERATE_SIGNATURES,
    GENERATE_IMPLEMENTATIONS,
    GENERATE_NONE,
    GENERATE_EXTERN_SIGNATURES,
};

class CXXGenerator : public __AST_VISITOR::Visitor {
  private:
    bool __generate_signatures        = false;
    bool __generate_implementations   = false;
    bool __generate_extern_signatures = false;

  public:
    CXXGenerator() = default;
    explicit CXXGenerator(GenerateMode) noexcept;
    virtual ~CXXGenerator()                       = default;
    CXXGenerator(const CXXGenerator &)            = default;
    CXXGenerator &operator=(const CXXGenerator &) = default;
    CXXGenerator(CXXGenerator &&)                 = default;
    CXXGenerator &operator=(CXXGenerator &&)      = default;
};
}  // namespace codegen::cxx

#endif  // __CXX_EMITTER_HH__