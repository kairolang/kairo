"""Operand generator biased toward the hard cases."""
import random
from wfo import Fmt


def rand_val(f, rng, near=None):
    r = rng.random()
    s = rng.getrandbits(1)
    if r < 0.03:
        return f.qnan() if rng.random() < .5 else f.qnan() | rng.getrandbits(f.mbits - 1) | (s << (f.nbits - 1))
    if r < 0.06:
        return f.inf(s)
    if r < 0.09:
        return f.zero(s)
    if r < 0.12:          # subnormal
        return (s << (f.nbits - 1)) | rng.getrandbits(rng.randint(1, f.mbits))
    if r < 0.15:          # tiny normal
        e = rng.randint(1, 4)
    elif r < 0.18:        # huge
        e = f.emask - rng.randint(1, 4)
    elif r < 0.30:        # mid
        e = f.bias + rng.randint(-8, 8)
    elif r < 0.40 and near is not None:   # close to another value: cancellation
        ne = (near >> f.mbits) & f.emask
        if 0 < ne < f.emask:
            e = max(1, min(f.emask - 1, ne + rng.randint(-2, 2)))
            m = near & f.fmask
            k = rng.random()
            if k < .3:
                m ^= rng.getrandbits(rng.randint(1, 12))
            elif k < .6:
                m = (m + rng.randint(-3, 3)) & f.fmask
            return (s << (f.nbits - 1)) | (e << f.mbits) | m
        e = rng.randint(1, f.emask - 1)
    else:
        e = rng.randint(1, f.emask - 1)
    k = rng.random()
    if k < .15:
        m = f.fmask                                   # all ones
    elif k < .3:
        m = 1 << rng.randrange(f.mbits)               # sparse
    elif k < .4:
        m = rng.getrandbits(min(8, f.mbits)) << max(0, f.mbits - 8)       # short
    elif k < .5:
        m = f.fmask ^ (1 << rng.randrange(f.mbits))
    else:
        m = rng.getrandbits(f.mbits)
    return (s << (f.nbits - 1)) | (e << f.mbits) | m
