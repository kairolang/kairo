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

ffi "c++" import "set"

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
    priv var _kairo_source: cxx::std::set<string> = cxx::std::set<string>()
    priv var _kairo_lib:    cxx::std::set<string> = cxx::std::set<string>()
    priv var _cxx_source:   cxx::std::set<string> = cxx::std::set<string>()
    priv var _cxx_header:   cxx::std::set<string> = cxx::std::set<string>()

    fn FileExtensions(self) {
        // kairo
        self._kairo_source.insert("k")
        self._kairo_lib.insert("hlib")

        // c++
        self._cxx_source.insert("cpp")
        self._cxx_source.insert("cc")
        self._cxx_source.insert("cxx")
        self._cxx_source.insert("c++")
        self._cxx_source.insert("C")
        self._cxx_source.insert("c")
        self._cxx_source.insert("CPP")

        self._cxx_header.insert("tpp")
        self._cxx_header.insert("txx")
        self._cxx_header.insert("t++")
        self._cxx_header.insert("T")
        self._cxx_header.insert("TPP")

        self._cxx_header.insert("hpp")
        self._cxx_header.insert("hh")
        self._cxx_header.insert("hxx")
        self._cxx_header.insert("h++")
        self._cxx_header.insert("H")
        self._cxx_header.insert("h")

        self._cxx_header.insert("HPP")
        self._cxx_header.insert("HH")
        self._cxx_header.insert("HXX")
        self._cxx_header.insert("H++")
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

    // `const`: by reference. By value, every categorize() copied up to
    // four std::sets of strings per directory entry indexed.
    priv fn contains(self, const li: cxx::std::set<string>, const ext: string) -> bool {
        return li.contains(ext)
    }
}
