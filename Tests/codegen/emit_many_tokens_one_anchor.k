// A macro's expansion is emitted at the call, so every token of its body is
// anchored on the call's bytes. Here the expansions emit many times more C++
// tokens than the file has bytes: once every byte after the calls is taken,
// each further token walks back from its call across every taken byte before
// it. The comment block below only lengthens that run of taken bytes; the
// walk has to stay cheap however many tokens have crossed it before.

var acc: i64 = 0

macro step!(x) {
    {
        var a: i64 = x
        var b: i64 = a * 3 + 1
        var c: i64 = (a ^ b) + (b >> 2) - (a << 1)
        if c > 100 {
            acc = acc + c % 7
        } else if c < -100 {
            acc = acc - c % 5
        } else {
            acc = acc + a + b + c
        }

        for var i: i64 = 0; i < 2; i += 1 {
            acc = (acc * 31 + i + a - b) % 1000003
        }
    }
}

macro four!(x) {
    step!(x)
    step!(x + 1)
    step!(x + 2)
    step!(x + 3)
}

macro sixteen!(x) {
    four!(x)
    four!(x + 4)
    four!(x + 8)
    four!(x + 12)
}

// Bytes for the walk to cross:
// 000: these bytes are taken by the expansions in main once their own are.
// 001: these bytes are taken by the expansions in main once their own are.
// 002: these bytes are taken by the expansions in main once their own are.
// 003: these bytes are taken by the expansions in main once their own are.
// 004: these bytes are taken by the expansions in main once their own are.
// 005: these bytes are taken by the expansions in main once their own are.
// 006: these bytes are taken by the expansions in main once their own are.
// 007: these bytes are taken by the expansions in main once their own are.
// 008: these bytes are taken by the expansions in main once their own are.
// 009: these bytes are taken by the expansions in main once their own are.
// 010: these bytes are taken by the expansions in main once their own are.
// 011: these bytes are taken by the expansions in main once their own are.
// 012: these bytes are taken by the expansions in main once their own are.
// 013: these bytes are taken by the expansions in main once their own are.
// 014: these bytes are taken by the expansions in main once their own are.
// 015: these bytes are taken by the expansions in main once their own are.
// 016: these bytes are taken by the expansions in main once their own are.
// 017: these bytes are taken by the expansions in main once their own are.
// 018: these bytes are taken by the expansions in main once their own are.
// 019: these bytes are taken by the expansions in main once their own are.
// 020: these bytes are taken by the expansions in main once their own are.
// 021: these bytes are taken by the expansions in main once their own are.
// 022: these bytes are taken by the expansions in main once their own are.
// 023: these bytes are taken by the expansions in main once their own are.
// 024: these bytes are taken by the expansions in main once their own are.
// 025: these bytes are taken by the expansions in main once their own are.
// 026: these bytes are taken by the expansions in main once their own are.
// 027: these bytes are taken by the expansions in main once their own are.
// 028: these bytes are taken by the expansions in main once their own are.
// 029: these bytes are taken by the expansions in main once their own are.
// 030: these bytes are taken by the expansions in main once their own are.
// 031: these bytes are taken by the expansions in main once their own are.
// 032: these bytes are taken by the expansions in main once their own are.
// 033: these bytes are taken by the expansions in main once their own are.
// 034: these bytes are taken by the expansions in main once their own are.
// 035: these bytes are taken by the expansions in main once their own are.
// 036: these bytes are taken by the expansions in main once their own are.
// 037: these bytes are taken by the expansions in main once their own are.
// 038: these bytes are taken by the expansions in main once their own are.
// 039: these bytes are taken by the expansions in main once their own are.
// 040: these bytes are taken by the expansions in main once their own are.
// 041: these bytes are taken by the expansions in main once their own are.
// 042: these bytes are taken by the expansions in main once their own are.
// 043: these bytes are taken by the expansions in main once their own are.
// 044: these bytes are taken by the expansions in main once their own are.
// 045: these bytes are taken by the expansions in main once their own are.
// 046: these bytes are taken by the expansions in main once their own are.
// 047: these bytes are taken by the expansions in main once their own are.
// 048: these bytes are taken by the expansions in main once their own are.
// 049: these bytes are taken by the expansions in main once their own are.
// 050: these bytes are taken by the expansions in main once their own are.
// 051: these bytes are taken by the expansions in main once their own are.
// 052: these bytes are taken by the expansions in main once their own are.
// 053: these bytes are taken by the expansions in main once their own are.
// 054: these bytes are taken by the expansions in main once their own are.
// 055: these bytes are taken by the expansions in main once their own are.
// 056: these bytes are taken by the expansions in main once their own are.
// 057: these bytes are taken by the expansions in main once their own are.
// 058: these bytes are taken by the expansions in main once their own are.
// 059: these bytes are taken by the expansions in main once their own are.
// 060: these bytes are taken by the expansions in main once their own are.
// 061: these bytes are taken by the expansions in main once their own are.
// 062: these bytes are taken by the expansions in main once their own are.
// 063: these bytes are taken by the expansions in main once their own are.
// 064: these bytes are taken by the expansions in main once their own are.
// 065: these bytes are taken by the expansions in main once their own are.
// 066: these bytes are taken by the expansions in main once their own are.
// 067: these bytes are taken by the expansions in main once their own are.
// 068: these bytes are taken by the expansions in main once their own are.
// 069: these bytes are taken by the expansions in main once their own are.
// 070: these bytes are taken by the expansions in main once their own are.
// 071: these bytes are taken by the expansions in main once their own are.
// 072: these bytes are taken by the expansions in main once their own are.
// 073: these bytes are taken by the expansions in main once their own are.
// 074: these bytes are taken by the expansions in main once their own are.
// 075: these bytes are taken by the expansions in main once their own are.
// 076: these bytes are taken by the expansions in main once their own are.
// 077: these bytes are taken by the expansions in main once their own are.
// 078: these bytes are taken by the expansions in main once their own are.
// 079: these bytes are taken by the expansions in main once their own are.
// 080: these bytes are taken by the expansions in main once their own are.
// 081: these bytes are taken by the expansions in main once their own are.
// 082: these bytes are taken by the expansions in main once their own are.
// 083: these bytes are taken by the expansions in main once their own are.
// 084: these bytes are taken by the expansions in main once their own are.
// 085: these bytes are taken by the expansions in main once their own are.
// 086: these bytes are taken by the expansions in main once their own are.
// 087: these bytes are taken by the expansions in main once their own are.
// 088: these bytes are taken by the expansions in main once their own are.
// 089: these bytes are taken by the expansions in main once their own are.
// 090: these bytes are taken by the expansions in main once their own are.
// 091: these bytes are taken by the expansions in main once their own are.
// 092: these bytes are taken by the expansions in main once their own are.
// 093: these bytes are taken by the expansions in main once their own are.
// 094: these bytes are taken by the expansions in main once their own are.
// 095: these bytes are taken by the expansions in main once their own are.
// 096: these bytes are taken by the expansions in main once their own are.
// 097: these bytes are taken by the expansions in main once their own are.
// 098: these bytes are taken by the expansions in main once their own are.
// 099: these bytes are taken by the expansions in main once their own are.
// 100: these bytes are taken by the expansions in main once their own are.
// 101: these bytes are taken by the expansions in main once their own are.
// 102: these bytes are taken by the expansions in main once their own are.
// 103: these bytes are taken by the expansions in main once their own are.
// 104: these bytes are taken by the expansions in main once their own are.
// 105: these bytes are taken by the expansions in main once their own are.
// 106: these bytes are taken by the expansions in main once their own are.
// 107: these bytes are taken by the expansions in main once their own are.
// 108: these bytes are taken by the expansions in main once their own are.
// 109: these bytes are taken by the expansions in main once their own are.
// 110: these bytes are taken by the expansions in main once their own are.
// 111: these bytes are taken by the expansions in main once their own are.
// 112: these bytes are taken by the expansions in main once their own are.
// 113: these bytes are taken by the expansions in main once their own are.
// 114: these bytes are taken by the expansions in main once their own are.
// 115: these bytes are taken by the expansions in main once their own are.
// 116: these bytes are taken by the expansions in main once their own are.
// 117: these bytes are taken by the expansions in main once their own are.
// 118: these bytes are taken by the expansions in main once their own are.
// 119: these bytes are taken by the expansions in main once their own are.
// 120: these bytes are taken by the expansions in main once their own are.
// 121: these bytes are taken by the expansions in main once their own are.
// 122: these bytes are taken by the expansions in main once their own are.
// 123: these bytes are taken by the expansions in main once their own are.
// 124: these bytes are taken by the expansions in main once their own are.
// 125: these bytes are taken by the expansions in main once their own are.
// 126: these bytes are taken by the expansions in main once their own are.
// 127: these bytes are taken by the expansions in main once their own are.
// 128: these bytes are taken by the expansions in main once their own are.
// 129: these bytes are taken by the expansions in main once their own are.
// 130: these bytes are taken by the expansions in main once their own are.
// 131: these bytes are taken by the expansions in main once their own are.
// 132: these bytes are taken by the expansions in main once their own are.
// 133: these bytes are taken by the expansions in main once their own are.
// 134: these bytes are taken by the expansions in main once their own are.
// 135: these bytes are taken by the expansions in main once their own are.
// 136: these bytes are taken by the expansions in main once their own are.
// 137: these bytes are taken by the expansions in main once their own are.
// 138: these bytes are taken by the expansions in main once their own are.
// 139: these bytes are taken by the expansions in main once their own are.
// 140: these bytes are taken by the expansions in main once their own are.
// 141: these bytes are taken by the expansions in main once their own are.
// 142: these bytes are taken by the expansions in main once their own are.
// 143: these bytes are taken by the expansions in main once their own are.
// 144: these bytes are taken by the expansions in main once their own are.
// 145: these bytes are taken by the expansions in main once their own are.
// 146: these bytes are taken by the expansions in main once their own are.
// 147: these bytes are taken by the expansions in main once their own are.
// 148: these bytes are taken by the expansions in main once their own are.
// 149: these bytes are taken by the expansions in main once their own are.
// 150: these bytes are taken by the expansions in main once their own are.
// 151: these bytes are taken by the expansions in main once their own are.
// 152: these bytes are taken by the expansions in main once their own are.
// 153: these bytes are taken by the expansions in main once their own are.
// 154: these bytes are taken by the expansions in main once their own are.
// 155: these bytes are taken by the expansions in main once their own are.
// 156: these bytes are taken by the expansions in main once their own are.
// 157: these bytes are taken by the expansions in main once their own are.
// 158: these bytes are taken by the expansions in main once their own are.
// 159: these bytes are taken by the expansions in main once their own are.
// 160: these bytes are taken by the expansions in main once their own are.
// 161: these bytes are taken by the expansions in main once their own are.
// 162: these bytes are taken by the expansions in main once their own are.
// 163: these bytes are taken by the expansions in main once their own are.
// 164: these bytes are taken by the expansions in main once their own are.
// 165: these bytes are taken by the expansions in main once their own are.
// 166: these bytes are taken by the expansions in main once their own are.
// 167: these bytes are taken by the expansions in main once their own are.
// 168: these bytes are taken by the expansions in main once their own are.
// 169: these bytes are taken by the expansions in main once their own are.
// 170: these bytes are taken by the expansions in main once their own are.
// 171: these bytes are taken by the expansions in main once their own are.
// 172: these bytes are taken by the expansions in main once their own are.
// 173: these bytes are taken by the expansions in main once their own are.
// 174: these bytes are taken by the expansions in main once their own are.
// 175: these bytes are taken by the expansions in main once their own are.
// 176: these bytes are taken by the expansions in main once their own are.
// 177: these bytes are taken by the expansions in main once their own are.
// 178: these bytes are taken by the expansions in main once their own are.
// 179: these bytes are taken by the expansions in main once their own are.
// 180: these bytes are taken by the expansions in main once their own are.
// 181: these bytes are taken by the expansions in main once their own are.
// 182: these bytes are taken by the expansions in main once their own are.
// 183: these bytes are taken by the expansions in main once their own are.
// 184: these bytes are taken by the expansions in main once their own are.
// 185: these bytes are taken by the expansions in main once their own are.
// 186: these bytes are taken by the expansions in main once their own are.
// 187: these bytes are taken by the expansions in main once their own are.
// 188: these bytes are taken by the expansions in main once their own are.
// 189: these bytes are taken by the expansions in main once their own are.
// 190: these bytes are taken by the expansions in main once their own are.
// 191: these bytes are taken by the expansions in main once their own are.
// 192: these bytes are taken by the expansions in main once their own are.
// 193: these bytes are taken by the expansions in main once their own are.
// 194: these bytes are taken by the expansions in main once their own are.
// 195: these bytes are taken by the expansions in main once their own are.
// 196: these bytes are taken by the expansions in main once their own are.
// 197: these bytes are taken by the expansions in main once their own are.
// 198: these bytes are taken by the expansions in main once their own are.
// 199: these bytes are taken by the expansions in main once their own are.

fn main() -> i32 {
    sixteen!(0)
    sixteen!(16)
    sixteen!(32)
    sixteen!(48)
    sixteen!(64)
    sixteen!(80)
    sixteen!(96)
    sixteen!(112)
    sixteen!(128)
    sixteen!(144)
    sixteen!(160)
    sixteen!(176)
    sixteen!(192)
    sixteen!(208)
    sixteen!(224)
    sixteen!(240)
    if acc < 0 {
        return 1
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
