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

pub enum FileCategory {
    KairoSource,  ///< .k files
    KairoLibrary, ///< .hlib archives
    CxxSource,    ///< .cpp, .cc, .cxx, .c++ files
    CxxHeader,    ///< .hpp, .hh, .hxx, .h++, .h files
    CSource,      ///< .c files
    CHeader,      ///< .h files (also in CxxHeader, duplicated for C-only lookups)
    Other,        ///< everything else we index
    Ignored,      ///< files we don't index
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
        if ext.empty() {
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

    fn is_kairo_source(self, const ext: string) -> bool {
        return self.contains(self._kairo_source, ext)
    }

    fn is_kairo_lib(self, const ext: string) -> bool {
        return self.contains(self._kairo_lib, ext)
    }

    fn is_cxx_source(self, const ext: string) -> bool {
        return self.contains(self._cxx_source, ext)
    }

    fn is_cxx_header(self, const ext: string) -> bool {
        return self.contains(self._cxx_header, ext)
    }

    fn is_any_source(self, const ext: string) -> bool {
        return self.is_kairo_source(ext) || self.is_cxx_source(ext)
    }

    fn is_any_header(self, const ext: string) -> bool {
        return self.is_cxx_header(ext)
    }

    fn add_kairo_source(self, const ext: string) {
        self._kairo_source.insert(ext)
    }

    fn add_kairo_lib(self, const ext: string) {
        self._kairo_lib.insert(ext)
    }

    fn add_cxx_source(self, const ext: string) {
        self._cxx_source.insert(ext)
    }

    fn add_cxx_header(self, const ext: string) {
        self._cxx_header.insert(ext)
    }

    // Views, not copies: a getter returning the set by value copied up to
    // four sets of strings per call. The set lives as long as this object.
    fn kairo_source_exts(self) -> unsafe *cxx::std::set<string> {
        return unsafe &self._kairo_source
    }

    fn kairo_lib_exts(self) -> unsafe *cxx::std::set<string> {
        return unsafe &self._kairo_lib
    }

    fn cxx_source_exts(self) -> unsafe *cxx::std::set<string> {
        return unsafe &self._cxx_source
    }

    fn cxx_header_exts(self) -> unsafe *cxx::std::set<string> {
        return unsafe &self._cxx_header
    }

    // `const`: by reference. By value, every categorize() copied up to
    // four std::sets of strings per directory entry indexed.
    priv fn contains(self, const li: cxx::std::set<string>, const ext: string) -> bool {
        return li.contains(ext)
    }
}
