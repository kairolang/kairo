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
    priv var _kairo_source: [string]
    priv var _kairo_lib:    [string]
    priv var _cxx_source:   [string]
    priv var _cxx_header:   [string]

    fn FileExtensions(self) {
        // kairo
        self._kairo_source.push("k")
        self._kairo_lib.push("hlib")

        // c++
        self._cxx_source.push("cpp")
        self._cxx_source.push("cc")
        self._cxx_source.push("cxx")
        self._cxx_source.push("c++")
        self._cxx_source.push("C")
        self._cxx_source.push("c")
        self._cxx_source.push("CPP")

        self._cxx_header.push("tpp")
        self._cxx_header.push("txx")
        self._cxx_header.push("t++")
        self._cxx_header.push("T")
        self._cxx_header.push("TPP")

        self._cxx_header.push("hpp")
        self._cxx_header.push("hh")
        self._cxx_header.push("hxx")
        self._cxx_header.push("h++")
        self._cxx_header.push("H")
        self._cxx_header.push("h")

        self._cxx_header.push("HPP")
        self._cxx_header.push("HH")
        self._cxx_header.push("HXX")
        self._cxx_header.push("H++")
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
    priv fn contains(self, const li: [string], const ext: string) -> bool {
        for const *e in li {
            if *e == ext {
                return true
            }
        }

        return false
    }
}
