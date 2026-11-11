/// --- The Kairo Project -------------------------- Driver/InputKinds.k --- ///
///
///   What each command-line input is: the one classifier.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   Every place the driver asks "is this a Kairo file, a C/C++ source, an
///   object?" asks here. One function, one rule, and the extension is normalized
///   once: per-caller extension lists drift apart when Path::extension()'s
///   spelling (with or without the dot) changes, and a list that stops
///   matching lexes every .c/.cc/.o as Kairo.
///
///   The table is clang's own (clang::driver::types), not a copy: an input
///   kairo hands to clang is classified exactly as clang would classify it,
///   and -x takes clang's type names. Kairo adds only what clang does not
///   know: `.k`, and the link inputs clang has no type for (.a, .so, ...).
///
///   Deliberate deviation: clang treats any file with an unknown extension
///   as an object and lets the linker fail on it. Here it is an error naming
///   -x, because lld's message for a text file is unreadable.
///

ffi "c++" import "clang/Driver/Types.h"
ffi "c++" import "Native/Types.hh" // sref
ffi "c++" import "string"

import Support::FileIO::Path::Path

/// What the driver does with an input.
pub enum InputClass derives u8 {
    Kairo,       ///< a .k translation unit: FrontendAction
    Source,      ///< compiled by clang: C, C++, ObjC/ObjC++, OpenCL, IR, preprocessed
    Header,      ///< precompiled by clang to a .pch; never linked
    LinkInput,   ///< object, archive or shared library: straight to the link
    Unsupported, ///< a kind clang knows that this toolchain cannot build (why says which)
    Unknown,     ///< no extension kairo or clang recognizes, and no -x
    BadLanguage, ///< -x named a language that does not exist
}

pub class InputKind {
    pub var path:   string
    pub var cls:    InputClass               = InputClass::Unknown
    pub var ty:     clang::driver::types::ID = clang::driver::types::TY_INVALID
    pub var forced: string ///< the -x value in force for this input, "" if none
    /// A .k no command-line word names: a C++ input includes it
    /// (CompilerInstance::_discover_includes). Built and linked like any
    /// Kairo input, but never an output -o names.
    pub var discovered: bool   = false
    pub var why:        string         ///< the reason, for Unsupported / Unknown / BadLanguage

    /// clang's -x spelling of this input's type ("c++", "objective-c", ...).
    /// "kairo" for a Kairo input, "" when there is no type.
    fn type_name(self) -> string {
        if self.cls == InputClass::Kairo {
            return "kairo"
        }

        if self.ty == clang::driver::types::TY_INVALID {
            return ""
        }

        return string(
            unsafe ((clang::driver::types::getTypeName(self.ty) as unsafe *const u8) as *const u8),
        )
    }

    /// C, not C++: the libc++ include roots are left off its search path.
    fn is_c_family_c(self) -> bool {
        if self.cls != InputClass::Source && self.cls != InputClass::Header {
            return false
        }

        return !clang::driver::types::isCXX(self.ty) && !clang::driver::types::isLLVMIR(self.ty)
    }

    /// Still to be preprocessed, so it reads headers: not IR, not a .i/.ii.
    /// (clang's own test, isSrcFile.) Inputs that read none get no header
    /// roots, which clang would only warn about as unused.
    fn needs_headers(self) -> bool {
        if self.cls != InputClass::Source && self.cls != InputClass::Header {
            return false
        }

        return clang::driver::types::isSrcFile(self.ty)
    }

    fn is_ir(self) -> bool {
        return self.cls == InputClass::Source && clang::driver::types::isLLVMIR(self.ty)
    }
}

/// \brief the extension of \p path without its dot: "cc" for a/b.cc, "" for
///        none. Path::extension() keeps the dot (llvm::sys::path semantics);
///        every comparison below is against the bare spelling clang uses.
pub fn input_ext(const path: string) -> string {
    var e = Path(path).extension()
    if e.size() > 0 && e[0] == ('.' as u8) {
        return e.subslice(1, e.size())
    }

    return e
}

/// Link inputs clang has no type for. (.o, .obj and .lib ARE clang types,
/// TY_Object, and are classified through the table.)
pub fn _is_link_ext(const ext: string) -> bool {
    return ext == "a"
        || ext == "so"
        || ext == "dylib"
        || ext == "dll"
        || ext == "tbd"
        || ext == "res"
}

/// \brief the class of a clang type id. Ordered most specific first: a CUDA
///        header is offload before it is a header.
pub fn _class_of_type(k: *InputKind) {
    var ty = k->ty
    if ty == clang::driver::types::TY_INVALID {
        k->cls = InputClass::Unknown
        return
    }

    if ty == clang::driver::types::TY_Object {
        k->cls = InputClass::LinkInput
        return
    }

    // Assembly (cc1as runs in-process) and CUDA / HIP (clang's driver
    // plans the device tools, which ClangJobs spawns as clang would) are
    // plain clang sources: kcc accepts every input clang accepts.
    if clang::driver::types::onlyPrecompileType(ty) {
        k->cls = InputClass::Header
        return
    }

    // A precompiled module (.pcm), a serialized AST (.ast) and the rest of
    // clang's precompiled kinds compile to objects through clang too; what a
    // given one allows is the driver's call, as with clang.
    if ty == clang::driver::types::TY_PCH
        || ty == clang::driver::types::TY_ModuleFile
        || ty == clang::driver::types::TY_AST
        || ty == clang::driver::types::TY_API_INFO {
        k->cls = InputClass::Source
        return
    }

    // isAcceptedByClang is cc1's question; a preprocessed .s never reaches cc1
    // (the driver hands it straight to -cc1as) but is just as much clang's input.
    if clang::driver::types::isAcceptedByClang(ty) || ty == clang::driver::types::TY_PP_Asm {
        k->cls = InputClass::Source
        return
    }

    var tname = string(
        unsafe ((clang::driver::types::getTypeName(ty) as unsafe *const u8) as *const u8),
    )

    k->cls = InputClass::Unsupported
    k->why = f"{tname} input is not supported: clang does not compile it"
}

/// libfoo.so.1, libfoo.so.1.2.3: a versioned shared library, whose
/// "extension" is the last version number.
pub fn _is_versioned_so(const path: string) -> bool {
    var name       = Path(path).filename()
    var at:  usize = kairo::std::to_std_string(name).find(r".so.")
    return !(cxx::std::string::npos == at)
}

/// \brief classifies one input.
///
/// \param xlang the -x value in force when this input appeared on the command
///        line: "" or "none" means by extension, "kairo"/"k" a Kairo file,
///        anything else a clang type name (`c`, `c++`, `objective-c++`,
///        `ir`, `c++-header`, ...).
pub fn classify_input(const path: string, const xlang: string) -> InputKind {
    var k = InputKind()
    k.path = path
    var lang = xlang
    if lang == "none" {
        lang = ""
    }

    k.forced = lang
    var ext = input_ext(path)

    if lang == "kairo" || lang == "k" {
        // Module naming, --emit-headers paths and the object-dir mirror all
        // derive from the .k stem; nothing has ever run on another spelling.
        if ext != "k" {
            k.cls = InputClass::Unsupported
            k.why = "-x kairo requires a .k file"
            return k
        }

        k.cls = InputClass::Kairo
        return k
    }

    if !lang.empty() {
        k.ty = clang::driver::types::lookupTypeForTypeSpecifier(lang.c_str())
        if k.ty == clang::driver::types::TY_INVALID {
            k.cls = InputClass::BadLanguage
            k.why = f"language not recognized: '{lang}'"
            return k
        }

        _class_of_type(&k)
        return k
    }

    if path == "-" {
        k.cls = InputClass::Unknown
        k.why = "standard input has no extension; name its language with -x <lang>"
        return k
    }

    if ext == "k" {
        k.cls = InputClass::Kairo
        return k
    }

    if _is_link_ext(ext) || _is_versioned_so(path) {
        k.cls = InputClass::LinkInput
        return k
    }

    k.ty = clang::driver::types::lookupTypeForExtension(kairo::sref(ext))
    _class_of_type(&k)
    if k.cls == InputClass::Unknown {
        k.why = if (!ext.empty()) => (f"unknown input type '.{ext}'; name its language with -x <lang>")
                else => "input has no extension; name its language with -x <lang>"
        // Only reachable after a bare `--`, where every word is an input.
        // There is no clang passthrough: Kairo has its own spelling for the
        // codegen flags, and --cxx-flags carries clang words to C/C++ inputs.
        if path.size() > 1 && path[0] == ('-' as u8) {
            k.why = f"'{path}' after -- is an input, not a flag: give the kairo spelling before --, or --cxx-flags={path} for C/C++ inputs"
        }
    }

    return k
}
