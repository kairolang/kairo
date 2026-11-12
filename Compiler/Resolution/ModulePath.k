/// --- The Kairo Project ---------------------- Resolution/ModulePath.k --- ///
///
///   ModulePath: a module path as a list of identifier tokens.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"
ffi "c++" import "algorithm"

import Preprocessor::PreprocessorSymbolTable::PreprocessorSymbolTable
import Token::IdentifierToken::IdentifierToken

pub class ModulePath { // 256-bit class (32 bytes - max)
    pub var segments: cxx::std::vector<IdentifierToken> ///< each segment is an identifier token this does not include the "::" tokens

    fn as_string(const self, sym_table: unsafe *PreprocessorSymbolTable) -> string {
        if self.segments.size() == 0 {
            return "<global>"
        }

        var result: string = ""
        var back           = self.segments.back()

        result.reserve(self.segments.size() * 12)

        for seg in self.segments {
            result += seg.as_string(sym_table) + (if (seg != back) => "::" else => "")
        }

        return result
    }

    fn op < (const self, other: ModulePath) -> bool {
        var n = cxx::std::min(self.segments.size(), other.segments.size())

        for i in (0 as usize)..(n) {
            if self.segments[i].name != other.segments[i].name {
                return self.segments[i].name < other.segments[i].name
            }
        }

        return self.segments.size() < other.segments.size()
    }
}

/// `geo/vec.hh` for the module path `geo::vec`: where `--emit-headers` puts
/// a module's header under its output directory. The one statement of that
/// layout, for the emitter (CXXSpell::header_path) and for kals, which tells
/// the clangd bridge where the header is (Analyzer/Index/Worker.k).
pub fn header_path_of(const segs: cxx::std::vector<string>) -> string {
    var s = ""
    for var i: usize = 0; i < segs.size(); ++i {
        if i > 0 {
            s += "/"
        }

        s += segs[i]
    }

    s += ".hh"
    return s
}

// --- file and path spellings ---------------------------------------------------
//
// For the tools around the compiler (kals) that name Kairo files and paths
// without a ModulePath in hand. The compiler's own sites still spell them.

/// `k`: a Kairo source file's extension.
pub fn kairo_ext() -> string {
    return "k"
}

/// `.k`.
pub fn kairo_dot_ext() -> string {
    return "." + kairo_ext()
}

/// `module`: the stem of the file that makes a directory a module.
pub fn module_file_stem() -> string {
    return "module"
}

/// `module.k`: `geo/module.k` is the module `geo`.
pub fn module_file_name() -> string {
    return module_file_stem() + kairo_dot_ext()
}

/// `::`, between the segments of a module path.
pub fn path_separator() -> string {
    return "::"
}
