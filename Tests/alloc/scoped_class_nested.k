// Objects with an arena nested in one another: an arena class whose fields
// are arena objects of the same allocator and of another ArenaAllocator
// type, and an arena object inside a plain class. Each object keeps its own
// arena; building, using and destroying the outer object opens and closes
// every arena once, and each block goes back to the arena that served it.
import builtin::base::alloc::*
import inputs::counting_arenas::*
import std::io::println

// A second ArenaAllocator over a pool of its own: two arenas, counted.
static pool2:   [u8; 131072]
static used2:   [usize; 2]
static live2:   [u8; 2]
static cur2:    usize        = 0
static opened2: i32          = 0
static closed2: i32          = 0
static served2: [i32; 2]
static freed2:  [i32; 2]

fn base2(k: usize) -> unsafe *u8 {
    unsafe {
        return (&pool2[0] as unsafe *u8) + k * 65536
    }
}

class Other {
    pub static fn alloc(size: usize, align: usize) -> unsafe *u8 {
        check(cur2 != 0, "an Other allocation with an Other arena current")
        var k  = cur2 - 1
        var at = align_up(used2[k], align)
        if at + size > 65536 {
            return &null
        }

        used2[k] = at + size
        served2[k] += 1
        return base2(k) + at
    }

    pub static fn free(ptr: unsafe *u8, size: usize, align: usize) {
        freed2[((ptr as usize) - (base2(0) as usize)) / 65536] += 1
    }

    pub static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool {
        return n <= o
    }

    pub static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 {
        return realloc_by_copy<Other>(ptr, o, n, align)
    }

    pub static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 {
        return Other::alloc(size, align)
    }

    pub static fn arena_open() -> usize {
        for var k: usize = 0; k < 2; k += 1 {
            if live2[k] == 0 {
                live2[k] = 1
                used2[k] = 0
                opened2 += 1
                return k + 1
            }
        }

        __builtin_abort()
    }

    pub static fn arena_close(arena: usize) {
        live2[arena - 1] = 0
        closed2 += 1
    }

    pub static fn arena_enter(arena: usize) -> usize {
        var p = cur2
        cur2 = arena
        return p
    }

    pub static fn arena_leave(previous: usize) {
        cur2 = previous
    }

    pub static fn arena_range(arena: usize) -> (unsafe *u8, unsafe *u8) {
        return (base2(arena - 1), base2(arena - 1) + 65536)
    }
}

@set_scoped_allocator(Arenas)
class Log {
    pub var text: string
    fn Log(self) {
        self.text.push_str(
            "a log, built in its own arena ..........................................",
        )
    }

    fn add(self) {
        self.text.push_str(
            "more for the log ......................................................",
        )
    }

    fn id(const self) -> usize {
        return cur
    }
}

@set_scoped_allocator(Other)
class Note {
    pub var text: string
    fn Note(self) {
        self.text.push_str(
            "a note, built in an Other arena ........................................",
        )
    }

    fn add(self) {
        self.text.push_str(
            "more for the note .....................................................",
        )
    }
}

@set_scoped_allocator(Arenas)
class Pair {
    pub var left:  Log
    pub var name:  string
    pub var note:  Note
    pub var right: Log

    fn Pair(self) {
        self.name.push_str(
            "the pair's own name, from the pair's arena .............................",
        )
    }

    fn touch(self) {
        var mine = cur
        self.left.add()
        self.note.add()
        check(cur == mine, "back in the pair's arena")
        self.right.add()
        self.name.push_str(
            "more for the pair ......................................................",
        )
    }

    fn ids(const self) -> (usize, usize, usize) {
        return (cur, self.left.id(), self.right.id())
    }
}

class Plain {
    pub var log:  Log
    pub var text: string = "a plain class's field, from the global heap ..................."
}

fn main() -> i32 {
    {
        var p = Pair()
        var i = p.ids()
        check(
            i.0 != i.1 && i.0 != i.2 && i.1 != i.2,
            "the pair and its two logs have an arena each",
        )

        check(
            open_now() == 3 && opened2 - closed2 == 1,
            "and the note an Other arena",
        )

        p.touch()
        p.touch()
        check(
            served[i.0 - 1] >= 3 && served[i.1 - 1] >= 3 && served[i.2 - 1] >= 3,
            "each arena served its own object",
        )

        check(served2[0] >= 3, "the Other arena served the note")
        check(cur == 0 && cur2 == 0, "no arena current between calls")
    }

    check(opened == 3 && closed == 3, "the pair's arenas closed once each")
    check(opened2 == 1 && closed2 == 1, "the note's arena closed once")
    check(freed2[0] == served2[0], "the note's blocks went back to its arena")
    for var k: usize = 0; k < 3; k += 1 {
        check(freedn[k] == served[k], "every block went back to its arena")
    }

    {
        var q = Plain()
        q.log.add()
        check(
            open_now() == 1,
            "an arena object inside a plain class has its arena",
        )
    }

    check(opened == closed, "and closes it")
    check(cur == 0 && cur2 == 0, "no arena current at the end")
    println("ok")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
