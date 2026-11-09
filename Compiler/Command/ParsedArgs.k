/// --- The Kairo Project ------------------------- Command/ParsedArgs.k --- ///
///
///   ParsedArgs, the parsed flag values and input files of one command line.
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
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "Native/Types.hh"

import Command::FlagUtils::FlagValue

pub class ParsedArgs {
    pub var files: cxx::std::vector<string> ///< positional file paths
    /// Parallel to files: the -x language in force when each was seen ("" =
    /// by extension). Filled only when the Command tags positionals.
    pub var file_langs: cxx::std::vector<string>
    pub var ok:         bool                     = true ///< false if required fields missing / bounds violated

    /// StringMap, not DenseMap: _cell and get_list hand out pointers into
    /// the values, and a StringMap entry is its own allocation that a rehash
    /// never moves. Never iterated.
    priv var _map: llvm::StringMap<FlagValue>

    fn has(self, const key: string) -> bool {
        return self._map.contains(kairo::sref(key))
    }

    pub fn is_set(self, const key: string) -> bool {
        if !self._map.contains(kairo::sref(key)) {
            return false
        }

        return self._map[kairo::sref(key)].is_set
    }

    pub fn get_bool(self, const key: string) -> bool {
        if !self._map.contains(kairo::sref(key)) {
            return false
        }

        return self._map[kairo::sref(key)].as_bool()
    }

    pub fn get_string(self, const key: string) -> string {
        if !self._map.contains(kairo::sref(key)) {
            return ""
        }

        return self._map[kairo::sref(key)].as_string()
    }

    pub fn get_i32(self, const key: string) -> i32 {
        if !self._map.contains(kairo::sref(key)) {
            return 0
        }

        return self._map[kairo::sref(key)].as_i32()
    }

    fn get_f64(self, const key: string) -> f64 {
        if !self._map.contains(kairo::sref(key)) {
            return 0.0
        }

        return self._map[kairo::sref(key)].as_f64()
    }

    pub fn get_list(self, const key: string) -> unsafe *cxx::std::vector<string> {
        return self._map[kairo::sref(key)].as_list()
    }

    /// \brief returns -1 (unset), 0 (-fno-{key}), or 1 (-f{key})
    pub fn get_feature(self, const key: string) -> i32 {
        if !self._map.contains(kairo::sref(key)) {
            return -1
        }

        return self._map[kairo::sref(key)].as_feature()
    }

    /// \brief config flag getters - key is without the 'c' CLI prefix
    fn get_cfg_bool(self, const key: string) -> bool {
        var k = f"c:{key}"
        if !self._map.contains(kairo::sref(k)) {
            return false
        }

        return self._map[kairo::sref(k)].as_bool()
    }

    pub fn get_cfg_i32(self, const key: string) -> i32 {
        var k = f"c:{key}"
        if !self._map.contains(kairo::sref(k)) {
            return 0
        }

        return self._map[kairo::sref(k)].as_i32()
    }

    pub fn get_cfg_f64(self, const key: string) -> f64 {
        var k = f"c:{key}"
        if !self._map.contains(kairo::sref(k)) {
            return 0.0
        }

        return self._map[kairo::sref(k)].as_f64()
    }

    fn get_cfg_str(self, const key: string) -> string {
        var k = f"c:{key}"
        if !self._map.contains(kairo::sref(k)) {
            return ""
        }

        return self._map[kairo::sref(k)].as_string()
    }

    pub fn cfg_is_set(self, const key: string) -> bool {
        var k = f"c:{key}"
        if !self._map.contains(kairo::sref(k)) {
            return false
        }

        return self._map[kairo::sref(k)].is_set
    }

    fn _init(self, const key: string, const dfl: FlagValue) {
        self._map[kairo::sref(key)] = dfl
    }

    fn _cell(self, const key: string) -> *FlagValue {
        return &self._map[kairo::sref(key)]
    }
}
