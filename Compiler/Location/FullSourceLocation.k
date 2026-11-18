/// --- The Kairo Project ---------------- Location/FullSourceLocation.k --- ///
///
///   FullSourceLocation: a position resolved to file, line and column.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Support::FileIO::Path::Path

/// fully resolved representation of a source position.
///
/// `FullSourceLocation` combines a low-level `SourceLocation` identifier
/// with its resolved file metadata, including file path, line, and column.
/// it's primarily used for diagnostics, debugging, and user-facing messages
/// where exact source coordinates are required.
///
/// unlike `SourceLocation`, which stores an opaque numeric id, this class
/// represents a concrete and human-readable position resolved through
/// the `SourceManager`.
///
/// each instance is immutable once constructed, and provides hashing and
/// equality semantics suitable for maps, sets, or diagnostic caches.
///
/// See SourceLocation, SourceManager, VirtualFileManager.

/// expanded view of a source location with file and position data.
///
/// stores the resolved file id, line number, column number, and associated
/// file path. intended for display or comparison rather than storage inside
/// parsing or semantic structures.
///
/// typical use cases:
///   - attaching user-readable position info to diagnostics
///   - representing precise code spans in tooling
///   - serializing source references for debugging or tracing
pub class FullSourceLocation {
    pub var file_id: usize = 0 ///< numeric file identifier.
    pub var line:    usize = 0 ///< 1-based line number.
    pub var column:  usize = 0 ///< 1-based column number.
    pub var path:    Path      ///< canonical file path.

    /// default constructor (invalid location).
    fn FullSourceLocation(self) {
        self.file_id = 0
        self.line    = 0
        self.column  = 0
        self.path    = Path("<invalid>", false)
    }

    /// constructs a fully resolved location.
    ///
    /// ### Parameters
    /// - `file_id`: unique file identifier.
    /// - `line`: line number (1-based).
    /// - `column`: column number (1-based).
    /// - `path`: path of the file containing the location.
    fn FullSourceLocation(self, file_id: usize, line: usize, column: usize, const path: Path) {
        self.file_id = file_id
        self.line    = line
        self.column  = column
        self.path    = path.copy()
    }

    /// checks whether this represents a valid source position.
    ///
    /// ### Returns
    /// true if all components are non-zero and valid.
    fn is_valid(self) -> bool {
        return self.file_id != 0 && self.line != 0 && self.column != 0
    }

    /// equality operator.
    ///
    /// compares all components except the file path string itself.
    fn op == (self, const other: FullSourceLocation) -> bool {
        return self.file_id == other.file_id
            && self.line == other.line
            && self.column == other.column
    }

    /// inequality operator.
    fn op != (self, const other: FullSourceLocation) -> bool {
        return self.file_id != other.file_id
            || self.line != other.line
            || self.column != other.column
    }

    /// string conversion operator.
    ///
    /// ### Returns
    /// formatted `"path:line:column"` string suitable for diagnostics.
    fn op as (self) -> string {
        return f"{self.path.full_path()}:{self.line}:{self.column}"
    }

    /// computes a stable hash for this location.
    ///
    /// uses a simple FNV-1a variant combining file id, line, and column.
    /// suitable for diagnostic deduplication or lookup tables.
    fn hash(self) -> u32 {
        var h: u32 = 0x811C9DC5
        h = (h ^ (self.file_id as u32)) * 0x01000193
        h = (h ^ (self.line as u32)) * 0x01000193
        h = (h ^ (self.column as u32)) * 0x01000193
        return h
    }
}
