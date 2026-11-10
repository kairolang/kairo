// The dev-harness driver: one request per line on stdin, one result per
// line on stdout (see the run_*.py scripts beside it for the requests).
// Build: kairo Scripts/softfloat_oracle/driver.k -O2 -o build/sfdrv

ffi "c" import "stdio.h"

import builtin::num::softfloat::*
import builtin::num::softfloat_text::*

fn hexval(c: u8) -> u32 {
    if c >= 48 && c <= 57 {
        return c - 48
    }

    if c >= 97 && c <= 102 {
        return c - 87
    }

    if c >= 65 && c <= 70 {
        return c - 55
    }

    return 99
}

/// Parses a hex token at line[*pos..] into w; skips spaces first.
fn parse_hex(line: unsafe *const u8, pos: *i32, w: *SfW) {
    sfw_zero(w, SFW_LIMBS)
    var p = *pos
    while line[p] == 32 {
        p += 1
    }

    var start = p
    while hexval(line[p]) != 99 {
        p += 1
    }

    var nd = p - start
    for var i: i32 = 0; i < nd; ++i {
        var d = hexval(line[p - 1 - i])
        w->w[i >> 3] = w->w[i >> 3] | d << (((i & 7) * 4) as u32)
    }

    *pos = p
}

fn parse_int(line: unsafe *const u8, pos: *i32) -> i32 {
    var p = *pos
    while line[p] == 32 {
        p += 1
    }

    var v: i32 = 0
    while line[p] >= 48 && line[p] <= 57 {
        v = v * 10 + ((line[p] - 48) as i32)
        p += 1
    }

    *pos = p
    return v
}

fn print_hex(w: *const SfW, nw: i32) {
    var buf: [u8; 600]
    var k:   i32       = 0
    var i              = nw * 8 - 1
    while i >= 0 {
        var d = w->w[i >> 3] >> (((i & 7) * 4) as u32) & 15
        buf[k] = (if d < 10 => 48 + d else => 87 + d) as u8
        k += 1
        i -= 1
    }

    buf[k] = 10
    unsafe {
        fwrite(&buf[0] as unsafe *const u8, 1, (k + 1) as usize, stdout)
    }
}

fn main() -> i32 {
    var line: [u8; 60000]
    var a:    SfW
    var b:    SfW
    var c:    SfW
    var r:    SfW
    while true {
        var ln: i32 = 0
        var ch: i32 = 0
        unsafe {
            ch = getchar()
        }

        if ch < 0 {
            break
        }

        while ch >= 0 && ch != 10 && ln < 59990 {
            line[ln] = ch as u8
            ln += 1
            unsafe {
                ch = getchar()
            }
        }

        line[ln] = 0
        var lp: unsafe *const u8 = &null
        unsafe {
            lp = &line[0] as unsafe *const u8
        }

        var opc      = line[0]
        var pos: i32 = 1
        var nb       = parse_int(lp, &pos)
        var eb       = parse_int(lp, &pos)
        var f        = sf_fmt(nb, eb)
        sfw_zero(&r, SFW_LIMBS)
        if opc == 97 { // a: add
            parse_hex(lp, &pos, &a)
            parse_hex(lp, &pos, &b)
            sf_add(f, &r, &a, &b, false)
        } else if opc == 115 { // s: sub
            parse_hex(lp, &pos, &a)
            parse_hex(lp, &pos, &b)
            sf_add(f, &r, &a, &b, true)
        } else if opc == 109 { // m: mul
            parse_hex(lp, &pos, &a)
            parse_hex(lp, &pos, &b)
            sf_mul(f, &r, &a, &b)
        } else if opc == 100 { // d: div
            parse_hex(lp, &pos, &a)
            parse_hex(lp, &pos, &b)
            sf_div(f, &r, &a, &b)
        } else if opc == 113 { // q: sqrt
            parse_hex(lp, &pos, &a)
            sf_sqrt(f, &r, &a)
        } else if opc == 102 { // f: fma
            parse_hex(lp, &pos, &a)
            parse_hex(lp, &pos, &b)
            parse_hex(lp, &pos, &c)
            sf_fma(f, &r, &a, &b, &c)
        } else if opc == 99 { // c: cmp -> 0 eq 1 lt 2 gt 3 un
            parse_hex(lp, &pos, &a)
            parse_hex(lp, &pos, &b)
            var k = sf_cmp(f, &a, &b)
            r.w[0] = 3
            if k == 0 {
                r.w[0] = 0
            } else if k == -1 {
                r.w[0] = 1
            } else if k == 1 {
                r.w[0] = 2
            }

            print_hex(&r, 1)
            continue
        } else if opc == 80 { // P: parse  P nb eb text
            while line[pos] == 32 {
                pos += 1
            }

            var tp: *const u8 = &line[pos]
            var ok            = sf_parse(f, &r, tp, (ln - pos) as usize)
            if !ok {
                r.w[0] = 0xDEAD
                print_hex(&r, 1)
                continue
            }
        } else if opc == 70 { // F: format  F nb eb prec conv hex
            while line[pos] == 32 {
                pos += 1
            }

            var neg = false
            if line[pos] == 45 {
                neg = true
                pos += 1
            }

            var prec = parse_int(lp, &pos)
            if neg {
                prec = -prec
            }

            while line[pos] == 32 {
                pos += 1
            }

            var conv = line[pos]
            pos += 1
            parse_hex(lp, &pos, &a)
            var buf: [u8; 2000]
            var nn:  i32        = 0
            unsafe {
                nn = sf_format(f, &a, &buf[0] as unsafe *u8, 1990, prec, conv)
            }

            buf[nn] = 10
            unsafe {
                fwrite(&buf[0] as unsafe *const u8, 1, (nn + 1) as usize, stdout)
            }

            continue
        } else if opc == 73 { // I: from int  I nb eb neg hexmag
            var ng = parse_int(lp, &pos)
            parse_hex(lp, &pos, &a)
            var all = sf_fmt(512, 15)
            var v   = sf_from_mag(f, sf_store(all, &a), ng != 0)
            sf_load(f, &r, v)
        } else if opc == 74 { // J: to int  J nb eb width signed hexbits
            var wd = parse_int(lp, &pos)
            var sg = parse_int(lp, &pos)
            parse_hex(lp, &pos, &a)
            var v   = sf_to_sat(f, sf_store(f, &a), wd, sg != 0)
            var all = sf_fmt(512, 15)
            sf_load(all, &r, v)
            print_hex(&r, 16)
            continue
        } else if opc == 88 { // X: from x87  X 0 0 hex80
            parse_hex(lp, &pos, &a)
            var m  = (a.w[0] as u64) | (a.w[1] as u64) << 32
            var se = (a.w[2] & 0xFFFF) as u16
            var v  = sf_from_x87(se, m)
            var g  = sf_fmt(79, 15)
            sf_load(g, &r, v)
            print_hex(&r, 3)
            continue
        } else if opc == 89 { // Y: to x87  Y 0 0 hex79
            parse_hex(lp, &pos, &a)
            var g       = sf_fmt(79, 15)
            var se: u16 = 0
            var m:  u64 = 0
            sf_to_x87(sf_store(g, &a), &se, &m)
            r.w[0] = m as u32
            r.w[1] = (m >> 32) as u32
            r.w[2] = se
            print_hex(&r, 3)
            continue
        } else if opc == 118 { // v: convert  v nb eb tnb teb a
            var tn = parse_int(lp, &pos)
            var te = parse_int(lp, &pos)
            parse_hex(lp, &pos, &a)
            var t = sf_fmt(tn, te)
            sf_convert(t, &r, f, &a)
            print_hex(&r, t.nw)
            continue
        }

        print_hex(&r, f.nw)
    }

    return 0
}
