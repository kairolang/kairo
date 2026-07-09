/// --- The Kairo Project ------------------------ Support/InternedStr.k --- ///
///
///   Lightweight interned string handle. Equality and hashing are O(1) integer
///   operations. Zero is the sentinel for the empty string.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class InternedStr {
    pub var id: u32;

    const fn op ==(self, other: InternedStr) -> bool { return self.id == other.id; }
    const fn op !=(self, other: InternedStr) -> bool { return self.id != other.id; }

    fn is_empty(self) -> bool { return self.id == 0; }

    static fn invalid() -> InternedStr {
        var s = InternedStr{};
        s.id  = u32(-1);
        return s;
    }

    /// \brief wraps a raw id (e.g. an ImmediateTable ident index) as a handle.
    ///        Post interner-consolidation the id space IS the per-fid imm ident
    ///        index, so a Token.imm can be lifted straight into a key.
    static fn from_id(id: u32) -> InternedStr {
        var s = InternedStr{};
        s.id  = id;
        return s;
    }

    fn is_valid(self) -> bool { return self.id != u32(-1); }
}

__inline_cpp("
struct InternedStrHash {
    size_t operator()(InternedStr s) const noexcept {
        return libcxx::hash<u32>{}(s.id);
    }
};
");