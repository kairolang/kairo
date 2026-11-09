# Archive Format (KaTAR)

KaTAR (`.ktar`) packs a directory tree into one file: file contents first, then a table of paths and byte ranges, then a trailer that locates the table. Directories are not stored; they are implied by the `/` separators in the paths. This document specifies the format as `Extras/KaTAR` implements it:

| File | Role |
|---|---|
| `Extras/KaTAR/KTCompress.k` | writer: `ktcompress <input_folder> <output_file>` |
| `Extras/KaTAR/KTDecompress.k` | reader: `ktextract <archive_file> <output_folder>` |
| `Extras/KaTAR/TableEntry.k` | `TableEntry { filename, offset, length }` |
| `Extras/KaTAR/UTF8.k` | `wstring` to UTF-8, without `<codecvt>` or locales |
| `Extras/KaTAR/Encode.k` | `usize` to decimal ASCII |

The format has no magic number and no version field, and stores no compression despite the writer's name.

## Layout

```text
[data]     for each file: its bytes, then one '\n'
[table]    for each file: <namelen>'\n' <name> <offset>'\n' <length>'\n'
[trailer]  <entry_count>'\n' <table_offset>'\n'
```

Every number is unsigned decimal ASCII, newline-terminated.

### Data section

Starts at byte 0. Each regular file's bytes are written as they are, followed by one `\n` separator that no table entry counts. The data section therefore ends at `table_offset`, which equals the sum of every file's length plus one byte per file.

### Table

One entry per file, in the order the writer met them:

| Field | Encoding |
|---|---|
| `namelen` | decimal byte length of `name`, then `\n` |
| `name` | `namelen` bytes of UTF-8, no terminator |
| `offset` | decimal byte offset of the file's first byte from the start of the archive, then `\n` |
| `length` | decimal byte length of the file's contents, then `\n` |

`name` is the file's path relative to the input folder in generic form (`/` separators), converted from the platform's wide string to UTF-8. It is length-prefixed, so a name may contain `\n`.

### Trailer

`entry_count` then `table_offset`, each a decimal line. Both are variable-width text, so the trailer has no fixed size: a reader finds it by scanning back from the end of the file.

## Reading

`KTDecompress` reads an archive as follows:

1. Scan backwards from the last byte for the third `\n`. The trailer starts after it. (The last two newlines end the trailer's two lines; the third ends the table's last entry, or the data section's last separator.)
2. Parse `entry_count` and `table_offset`.
3. Seek to `table_offset` and parse exactly `entry_count` entries: read the `namelen` line, read `namelen` raw bytes, then the `offset` and `length` lines.
4. For each entry, create the parent directories of `<output_folder>/<name>` and copy `length` bytes from `offset`.

## Writing

`KTCompress` walks the input folder with `std::filesystem::recursive_directory_iterator` and archives every entry for which `is_regular_file()` holds (a symlink to a regular file is followed and stored as a file). Directories, empty directories included, and special files are not stored. Entry order is the iteration order of the host's file system, so the archive of one tree is not byte-reproducible across machines.

## Limitations

- No validation on read: a `name` that is absolute or contains `..` is written outside the output folder, and a malformed trailer or table throws from `stoull` rather than producing a diagnostic.
- No file metadata (permissions, timestamps) is stored.
- The writer holds the whole data section in memory before writing it.
