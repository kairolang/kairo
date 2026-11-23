// The project is named after its directory's base name. Where the name must
// be a Kairo identifier (the library's `module` line, the import), every
// character outside [A-Za-z0-9_] becomes '_' and a leading digit gets a '_'
// in front; the build files keep the name as it is. With no directory, the
// project is the working directory, and the files are listed relative to it.

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t
// RUN: %kairo --init %t/my-app > /dev/null
// RUN: %FileCheck %s --check-prefix=MOD --input-file %t/my-app/include/module.k
// MOD: {{^}}module my_app{{$}}
// RUN: %FileCheck %s --check-prefix=MAIN --input-file %t/my-app/source/main.k
// MAIN: import my_app::calc
// RUN: %FileCheck %s --check-prefix=MK --input-file %t/my-app/Makefile
// MK: NAME = my-app
// RUN: %kairo --type-check-only %t/my-app/source/main.k -I %t/my-app/include
//
// A trailing separator names the same directory; a leading digit is prefixed.
// RUN: %kairo --init %t/9.lives/ > /dev/null
// RUN: %FileCheck %s --check-prefix=DIGIT --input-file %t/9.lives/include/module.k
// DIGIT: {{^}}module _9_lives{{$}}
//
// No directory: the working directory.
// RUN: mkdir -p %t/here && cd %t/here && %kairo --init | %FileCheck %s --check-prefix=HERE
// HERE: {{^}}created source/main.k{{$}}
// RUN: %FileCheck %s --check-prefix=HEREMOD --input-file %t/here/include/module.k
// HEREMOD: {{^}}module here{{$}}
