// --print-from-clang shows the reverse half of FlagTranslator: a clang driver
// command line (after --) as kairo CLI words, plus the clang words kairo has
// no flag for. kcc is kairo fed a clang command line, so this is what kcc
// will make of one. The kairo words are re-parsed by the real kairo parser:
// a row that maps to a flag that does not exist fails here.
//
// Tokenizing is clang's own option table: -Ifoo and -I foo are one option,
// -O is -O1 and -O4 is -O3 (clang's aliases), and clang-cl spellings do not
// match (-O2 is the driver's -O, not clang-cl's /O).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --print-from-clang -- -O2 -O -O4 -Os -g -gdwarf-4 -c a.cc b.k -o out.o | %FileCheck %s --check-prefix=OPT
// OPT:      kairo: -O2 -O1 -O3 -Os -g -g --dwarf-version=4 -c a.cc b.k -o out.o
// OPT-NEXT: clang-only:{{$}}

// clang's -I is kairo's -I: one flag, a clang header dir and a .k search dir.
// -D/-U are not kairo's (-D is a Kairo macro); they map to the clang-side
// flags. -std splits by language.
// RUN: %kairo --print-from-clang -- -Ifoo -I bar -DX=1 -UY -std=c++23 -std=gnu11 | %FileCheck %s --check-prefix=PP
// PP:      kairo: -I foo -I bar --cxx-define=X=1 --cxx-undefine=Y --cxx-std=c++23 --c-std=gnu11
// PP-NEXT: clang-only:{{$}}

// Codegen toggles keep their kairo spelling. -fPIC and -fpic are PIC levels
// 2 and 1 (small GOT), which kairo spells --pic-level.
// RUN: %kairo --print-from-clang -- -fno-exceptions -fno-rtti -fPIC -fomit-frame-pointer -ffunction-sections -fwrapv -mllvm -foo | %FileCheck %s --check-prefix=CG
// CG:      kairo: -fno-exceptions -fno-rtti --pic-level=2 -fomit-frame-pointer -ffunction-sections --signed-wrap --mllvm=-foo
// CG-NEXT: clang-only:{{$}}

// Target, warnings, link. -W<group> stays clang's; only the bulk switches
// are kairo flags.
// RUN: %kairo --print-from-clang -- --target=aarch64-linux-gnu -march=armv8-a -Wall -Werror -Wno-unused -lm -L/opt/lib -Wl,--gc-sections,-z,now -shared | %FileCheck %s --check-prefix=LINK
// LINK:      kairo: --target=aarch64-linux-gnu --march=armv8-a --Wall --Werror -l m -L /opt/lib --ld-flags=--gc-sections --ld-flags=-z --ld-flags=now --shared
// LINK-NEXT: clang-only: -Wno-unused{{$}}

// Actions: clang -E is kairo --preprocess (kairo -E is --error). -x stays
// positional.
// RUN: %kairo --print-from-clang -- -E a.c -x c++ b.txt -x none c.cc | %FileCheck %s --check-prefix=ACT
// ACT: kairo: --preprocess a.c -x c++ b.txt -x none c.cc

// Anything kairo has no flag for is kept, rendered as clang renders it.
// RUN: %kairo --print-from-clang -- -fvisibility=hidden -pthread -include foo.h a.cc | %FileCheck %s --check-prefix=RESID
// RESID:      kairo: a.cc
// RESID-NEXT: clang-only: -fvisibility=hidden -pthread -include foo.h

// A standard kairo has no choice for stays clang's (the C/C++ inputs get it).
// RUN: %kairo --print-from-clang -- -fpic -std=c++17 -std=c18 -std=c++23 | %FileCheck %s --check-prefix=STD
// STD:      kairo: --pic-level=1 --cxx-std=c++23
// STD-NEXT: clang-only: -std=c++17 -std=c18

// A clang option missing its value is an error, exit 1.
// RUN: { %kairo --print-from-clang -- -o 2>&1 || true; } | %FileCheck %s --check-prefix=MISS
// MISS: error [U001E]: clang option '-o' is missing its value
// RUN: not %kairo --print-from-clang -- -o > /dev/null 2>&1

// --cxx-define / --cxx-undefine reach clang (here: the shared cc1 line).
// RUN: %kairo %s --print-clang-args --cxx-define=FOO=1 --cxx-undefine=BAR | %FileCheck %s --check-prefix=DEF
// DEF: clang -cc1 {{.*}} -DFOO=1 -UBAR
