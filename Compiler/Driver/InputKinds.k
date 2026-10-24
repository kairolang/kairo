/// --- The Kairo Project -------------------------- Driver/InputKinds.k --- ///
///
///   What each command-line input is: the one classifier.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   Every place the driver asks "is this a Kairo file, a C/C++ source, an
///   object?" asks here. There used to be four hand-written extension lists
///   (_native_lang, _plan_outputs, execute, _runtime_sources), and when
///   Path::extension() started returning the dot three of them silently
///   stopped matching: every .c/.cc/.o was lexed as Kairo. One function, one
///   rule, and the extension is normalized once.
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

ffi "c++" import "clang/Driver/Types.h";
ffi "c++" import "Native/Types.hh";   // sref

import Support::FileIO::Path::*;

/// What the driver does with an input.
enum InputClass derives u8 {
    Kairo,        ///< a .k translation unit: FrontendAction
    Source,       ///< compiled by clang: C, C++, ObjC/ObjC++, OpenCL, IR, preprocessed
    Header,       ///< precompiled by clang to a .pch; never linked
    LinkInput,    ///< object, archive or shared library: straight to the link
    Unsupported,  ///< a kind clang knows that this toolchain cannot build (why says which)
    Unknown,      ///< no extension kairo or clang recognizes, and no -x
    BadLanguage,  ///< -x named a language that does not exist
}

class InputKind {
    pub var path:   string;
    pub var cls:    InputClass = InputClass::Unknown;
    pub var ty:     clang::driver::types::ID = clang::driver::types::TY_INVALID;
    pub var forced: string;   ///< the -x value in force for this input, "" if none
    /// A .k no command-line word names: a C++ input includes it
    /// (CompilerInstance::_discover_includes). Built and linked like any
    /// Kairo input, but never an output -o names.
    pub var discovered: bool = false;
    pub var why:    string;   ///< the reason, for Unsupported / Unknown / BadLanguage

    /// clang's -x spelling of this input's type ("c++", "objective-c", ...).
    /// "kairo" for a Kairo input, "" when there is no type.
    fn type_name(self) -> string {
        if self.cls == InputClass::Kairo { return "kairo"; }
        if self.ty == clang::driver::types::TY_INVALID { return ""; }
        return string(clang::driver::types::getTypeName(self.ty));
    }

    /// C, not C++: the libc++ include roots are left off its search path.
    fn is_c_family_c(self) -> bool {
        if (self.cls != InputClass::Source) && (self.cls != InputClass::Header) { return false; }
        return (!clang::driver::types::isCXX(self.ty)) && (!clang::driver::types::isLLVMIR(self.ty));
    }

    /// Still to be preprocessed, so it reads headers: not IR, not a .i/.ii.
    /// (clang's own test, isSrcFile.) Inputs that read none get no header
    /// roots, which clang would only warn about as unused.
    fn needs_headers(self) -> bool {
        if (self.cls != InputClass::Source) && (self.cls != InputClass::Header) { return false; }
        return clang::driver::types::isSrcFile(self.ty);
    }

    fn is_ir(self) -> bool {
        return (self.cls == InputClass::Source) && clang::driver::types::isLLVMIR(self.ty);
    }
}

/// \brief the extension of \p path without its dot: "cc" for a/b.cc, "" for
///        none. Path::extension() keeps the dot (llvm::sys::path semantics);
///        every comparison below is against the bare spelling clang uses.
fn input_ext(path: string) -> string {
    var e = Path(path).extension();
    if (e.size() > 0) && (e[0] == '.') { return e.subslice(1, e.size()); }
    return e;
}

/// Link inputs clang has no type for. (.o, .obj and .lib ARE clang types,
/// TY_Object, and are classified through the table.)
fn _is_link_ext(ext: string) -> bool {
    return (ext == "a") || (ext == "so") || (ext == "dylib") || (ext == "dll")
        || (ext == "tbd") || (ext == "res");
}

/// \brief the class of a clang type id. Ordered most specific first: a CUDA
///        header is offload before it is a header.
fn _class_of_type(k: *InputKind) {
    var ty = k->ty;
    if ty == clang::driver::types::TY_INVALID {
        (k->cls) = InputClass::Unknown;
        return;
    }
    if ty == clang::driver::types::TY_Object {
        (k->cls) = InputClass::LinkInput;
        return;
    }
    if (ty == clang::driver::types::TY_PP_Asm) || (ty == clang::driver::types::TY_Asm) {
        (k->cls) = InputClass::Unsupported;
        (k->why) = "assembly input is not supported yet: this build has no integrated assembler (cc1as)";
        return;
    }
    if clang::driver::types::isCuda(ty) || clang::driver::types::isHIP(ty) {
        (k->cls) = InputClass::Unsupported;
        (k->why) = "CUDA/HIP input is not supported: offload compilation needs external device tools (ptxas, fatbinary, clang-offload-bundler)";
        return;
    }
    if clang::driver::types::onlyPrecompileType(ty) {
        (k->cls) = InputClass::Header;
        return;
    }
    if (ty == clang::driver::types::TY_PCH) || (ty == clang::driver::types::TY_ModuleFile)
    || (ty == clang::driver::types::TY_AST) || (ty == clang::driver::types::TY_API_INFO) {
        (k->cls) = InputClass::Unsupported;
        (k->why) = "a precompiled file is not a compile input; pass it with --cxx-flags=-include-pch=<file> or as a module file";
        return;
    }
    if clang::driver::types::isAcceptedByClang(ty) {
        (k->cls) = InputClass::Source;
        return;
    }
    // Bound first: a qualified call inside an f-string hole is a shape the
    // bootstrap compiler mis-parses.
    var tname = string(clang::driver::types::getTypeName(ty));
    (k->cls) = InputClass::Unsupported;
    (k->why) = f"{tname} input is not supported: clang does not compile it";
}

/// libfoo.so.1, libfoo.so.1.2.3: a versioned shared library, whose
/// "extension" is the last version number.
fn _is_versioned_so(path: string) -> bool {
    var name = Path(path).filename();
    var at: usize = name.view().find(r".so.");
    return !(string::npos == at);
}

/// \brief classifies one input.
///
/// \param xlang the -x value in force when this input appeared on the command
///        line: "" or "none" means by extension, "kairo"/"k" a Kairo file,
///        anything else a clang type name (`c`, `c++`, `objective-c++`,
///        `ir`, `c++-header`, ...).
fn classify_input(path: string, xlang: string) -> InputKind {
    var k = InputKind();
    (k.path) = path;
    var lang = xlang;
    if lang == "none" { lang = ""; }
    (k.forced) = lang;
    var ext = input_ext(path);

    if (lang == "kairo") || (lang == "k") {
        // Module naming, --emit-headers paths and the object-dir mirror all
        // derive from the .k stem; nothing has ever run on another spelling.
        if ext != "k" {
            (k.cls) = InputClass::Unsupported;
            (k.why) = "-x kairo requires a .k file";
            return k;
        }
        (k.cls) = InputClass::Kairo;
        return k;
    }

    if !lang.empty() {
        (k.ty) = clang::driver::types::lookupTypeForTypeSpecifier(lang.c_str());
        if k.ty == clang::driver::types::TY_INVALID {
            (k.cls) = InputClass::BadLanguage;
            (k.why) = f"language not recognized: '{lang}\x27";
            return k;
        }
        _class_of_type(&k);
        return k;
    }

    if path == "-" {
        (k.cls) = InputClass::Unknown;
        (k.why) = "standard input has no extension; name its language with -x <lang>";
        return k;
    }
    if ext == "k" {
        (k.cls) = InputClass::Kairo;
        return k;
    }
    if _is_link_ext(ext) || _is_versioned_so(path) {
        (k.cls) = InputClass::LinkInput;
        return k;
    }

    (k.ty) = clang::driver::types::lookupTypeForExtension(sref(ext));
    _class_of_type(&k);
    if k.cls == InputClass::Unknown {
        (k.why) = (f"unknown input type '.{ext}\x27; name its language with -x <lang>")
                  if (!ext.empty()) else
                  ("input has no extension; name its language with -x <lang>");
    }
    return k;
}
