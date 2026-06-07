# KaTAR Format — Structure Draft v0.1

## Overview

KaTAR is a single-file archive format for Kairo projects. It stores raw file data contiguously, followed by a lookup table and a trailing offset to locate that table. Directory structure is inferred from `/` delimiters in file paths — no explicit folder entries are stored.

---

## File Structure

A typical Kairo project layout:

```
my_kairo_project/
├── build.k
├── src/
│   ├── hello.k
│   └── world.k
└── include/
    └── hello.hh
```

Storage layout:

<my_kairo_project.ktar>
<content>
    [rawdata build.k]           // Bytes 0 to 149
    [rawdata src/hello.k]       // Bytes 150 to 449
    [rawdata src/world.k]       // Bytes 450 to 699
    [rawdata include/hello.hh]  // Bytes 700 to 799
</content>
<table>
    <"build.k", 0, 150>
    <"src/hello.k", 150, 300>
    <"src/world.k", 450, 250>
    <"include/hello.hh", 700, 100>
</table>
<tableOffset = 800>

## Design Notes

- **Content block** holds raw file bytes, stored contiguously with no padding or alignment.
- **Table** is written after all content and maps paths to their byte ranges.
- **`tableOffset`** is a fixed-position trailer value that points to the start of the table, enabling O(1) table location on open.
- **Directories** are not stored explicitly — they are inferred at read time from `/` separators in file paths.