/// --- The Kairo Project ------------------ Resolution/FileExtensions.k --- ///
///
///   FileCategory and FileExtensions: which extensions are source or header.
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

/// C is not a category of its own: `.c` is a CxxSource and `.h` a
/// CxxHeader. Import resolution looks up KairoSource only; the other
/// categories decide only that a file is indexed.
pub enum FileCategory {
    KairoSource, ///< .k files
    KairoLibrary, ///< .hlib archives
    CxxSource, ///< .cpp, .cc, .cxx, .c++, .C, .CPP, .c files
    CxxHeader, ///< .hpp, .hh, .hxx, .h++, .h, .tpp, .txx, .t++ and their upper-case forms, and extensionless files
    Ignored, ///< files we don't index
}

pub class FileExtensions {
    priv var _kairo_source: cxx::std::vector<string>
    priv var _kairo_lib:    cxx::std::vector<string>
    priv var _cxx_source:   cxx::std::vector<string>
    priv var _cxx_header:   cxx::std::vector<string>

    fn FileExtensions(self) {
        // kairo
        self._kairo_source.push_back("k")
        self._kairo_lib.push_back("hlib")

        // c++
        self._cxx_source.push_back("cpp")
        self._cxx_source.push_back("cc")
        self._cxx_source.push_back("cxx")
        self._cxx_source.push_back("c++")
        self._cxx_source.push_back("C")
        self._cxx_source.push_back("c")
        self._cxx_source.push_back("CPP")

        self._cxx_header.push_back("tpp")
        self._cxx_header.push_back("txx")
        self._cxx_header.push_back("t++")
        self._cxx_header.push_back("T")
        self._cxx_header.push_back("TPP")

        self._cxx_header.push_back("hpp")
        self._cxx_header.push_back("hh")
        self._cxx_header.push_back("hxx")
        self._cxx_header.push_back("h++")
        self._cxx_header.push_back("H")
        self._cxx_header.push_back("h")

        self._cxx_header.push_back("HPP")
        self._cxx_header.push_back("HH")
        self._cxx_header.push_back("HXX")
        self._cxx_header.push_back("H++")
    }

    fn categorize(self, const ext: string) -> FileCategory {
        if ext.is_empty() {
            return FileCategory::CxxHeader
        }

        if self.contains(self._kairo_source, ext) {
            return FileCategory::KairoSource
        }

        if self.contains(self._kairo_lib, ext) {
            return FileCategory::KairoLibrary
        }

        if self.contains(self._cxx_source, ext) {
            return FileCategory::CxxSource
        }

        if self.contains(self._cxx_header, ext) {
            return FileCategory::CxxHeader
        }

        return FileCategory::Ignored
    }

    fn should_index(self, const ext: string) -> bool {
        return self.categorize(ext) != FileCategory::Ignored
    }

    // `const`: by reference. A vector, not a std::set: the lists hold a
    // dozen short names, and a std::set needs a C++ `<` the Kairo string
    // does not define on every builtin library.
    priv fn contains(self, const li: cxx::std::vector<string>, const ext: string) -> bool {
        for *e in li {
            if *e == ext {
                return true
            }
        }

        return false
    }
}
