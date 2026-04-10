/// --- The Kairo Project ----------------------------------- <filename> --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://kairo-lang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Kairo Software Foundation
///
/// ------------------------------------------------------------------------ ///

import ASTNode::Base::*;
import AST::ASTContext::*;
import AST::Support::*;

enum InlineBlockLang derives u8 {
    /// Clang: -x assembler-with-cpp
    /// inline "asm" { }
    Asm,

    /// Clang: -x c
    /// inline "c" { }
    C,

    /// Clang: -x c++
    /// inline "c++" { }
    Cxx,

    /// Clang: -x cuda  (requires CUDA toolkit)
    /// inline "cuda" { }
    Cuda,

    /// Clang: -x hip  (requires ROCm)
    /// inline "hip" { }
    Hip,

    /// Clang: -x opencl
    /// inline "OpenCL" { }
    OpenCL,

    /// Clang: -x hlsl  (Clang 15+)
    /// inline "hlsl" { }
    Hlsl,

    /// Apple metal compiler (xcrun metal), NOT standard Clang
    /// requires Apple toolchain
    /// inline "metal" { }
    Metal,

    /// OpenCL source compiled to SPIR-V via --target=spirv32/spirv64
    /// not a separate language, just OpenCL with a different target
    /// inline "spirv" { }
    SpirV,

    /// naga or tint compiler, NOT Clang
    /// requires separate WGSL toolchain
    /// inline "wgsl" { }
    Wgsl,

    /// glslang or shaderc, NOT Clang
    /// requires separate GLSL toolchain
    /// inline "glsl" { }
    Glsl,

    /// does absolutely nothing, just for fucks and giggles
    /// ACTUALLY MIGHT BE USEFUL FOR ADDING KAIRO DIRECTLY INTO C++ CODE
    /// inline "kairo" { }
    Kairo,
};