"""BLS12-381 as Aptos signs a ledger info, in pure Python, for the SYNTHETIC fixture's test keys: min-pk (keys in G1,
signatures in G2), `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`, the hash to G2 of RFC 9380 (section 8.8.2, its
isogeny constants from appendix E.3), and zkcrypto's compressed and uncompressed point encodings. It signs and encodes;
it does not verify, which the Rust statement does. Checked on import against RFC 9380's own vectors (J.10.1).

An aggregate of signatures on one message by keys `sk_i` is `(sum sk_i) * H(m)`, so the fixture signs each ledger info
once, with the sum of its signers' keys.
"""

import hashlib

P = 0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAAAB
R = 0x73EDA753299D7D483339D80809A1D80553BDA402FFFE5BFEFFFFFFFF00000001
DST = b"BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_"
H_EFF = int(
    "bc69f08f2ee75b3584c6a0ea91b352888e2a8e9145ad7689986ff031508ffe1329c2f178731db956d82bf015d1212b02ec0ec69d7477c1ae9"
    "54cbc06689f6a359894c0adebbf6b4e8020005aaa95551",
    16,
)
G1X = 0x17F1D3A73197D7942695638C4FA9AC0FC3688C4F9774B905A14E3A3F171BAC586C55E83FF97A1AEFFB3AF00ADB22C6BB
G1Y = 0x08B3F481E3AAA0F1A09E30ED741D8AE4FCF5E095D5D00AF600DB18CB2C04B3EDD03CC744A2888AE40CAA232946C5E7E1


# ---------------------------------------------------------------------------
# Fp2 = Fp[I] / (I^2 + 1), as pairs (c0, c1)
# ---------------------------------------------------------------------------


def f2(a, b=0):
    return (a % P, b % P)


def add(x, y):
    return ((x[0] + y[0]) % P, (x[1] + y[1]) % P)


def sub(x, y):
    return ((x[0] - y[0]) % P, (x[1] - y[1]) % P)


def mul(x, y):
    return ((x[0] * y[0] - x[1] * y[1]) % P, (x[0] * y[1] + x[1] * y[0]) % P)


def neg(x):
    return ((-x[0]) % P, (-x[1]) % P)


def inv(x):
    n = pow(x[0] * x[0] + x[1] * x[1], P - 2, P)
    return ((x[0] * n) % P, (-x[1] * n) % P)


ZERO, ONE = (0, 0), (1, 0)


def is_square_fp(a):
    return a % P == 0 or pow(a, (P - 1) // 2, P) == 1


def sqrt_fp(a):
    r = pow(a, (P + 1) // 4, P)
    return r if r * r % P == a % P else None


def is_square(x):
    return is_square_fp(x[0] * x[0] + x[1] * x[1])


def sqrt(x):
    """A square root in Fp2, or None."""
    a0, a1 = x
    if a1 == 0:
        r = sqrt_fp(a0)
        if r is not None:
            return (r, 0)
        r = sqrt_fp(-a0 % P)
        return (0, r) if r is not None else None
    g = sqrt_fp((a0 * a0 + a1 * a1) % P)
    if g is None:
        return None
    half = pow(2, P - 2, P)
    d = (a0 + g) * half % P
    x0 = sqrt_fp(d)
    if x0 is None:
        x0 = sqrt_fp((a0 - g) * half % P)
    if x0 is None or x0 == 0:
        return None
    x1 = a1 * pow(2 * x0, P - 2, P) % P
    r = (x0, x1)
    return r if mul(r, r) == (a0 % P, a1 % P) else None


def sgn0(x):
    """RFC 9380, section 4.1, for m = 2."""
    return (x[0] % 2) | ((x[0] == 0) & (x[1] % 2))


# ---------------------------------------------------------------------------
# hash to G2 (RFC 9380)
# ---------------------------------------------------------------------------


def expand_message_xmd(msg, dst, n):
    b0 = hashlib.sha256(bytes(64) + msg + n.to_bytes(2, "big") + b"\x00" + dst + bytes([len(dst)])).digest()
    out = b""
    prev = hashlib.sha256(b0 + b"\x01" + dst + bytes([len(dst)])).digest()
    out += prev
    i = 2
    while len(out) < n:
        prev = hashlib.sha256(bytes(a ^ b for a, b in zip(b0, prev)) + bytes([i]) + dst + bytes([len(dst)])).digest()
        out += prev
        i += 1
    return out[:n]


def hash_to_field(msg, dst):
    u = expand_message_xmd(msg, dst, 256)
    e = [int.from_bytes(u[64 * j:64 * j + 64], "big") % P for j in range(4)]
    return [(e[0], e[1]), (e[2], e[3])]


A_ISO = (0, 240)
B_ISO = (1012, 1012)
Z = f2(-2, -1)

# RFC 9380, appendix E.3: k_(i,j), read from the RFC's text.
K = {
    (1, 0): (0x5C759507E8E333EBB5B7A9A47D7ED8532C52D39FD3A042A88B58423C50AE15D5C2638E343D9C71C6238AAAAAAAA97D6,
             0x5C759507E8E333EBB5B7A9A47D7ED8532C52D39FD3A042A88B58423C50AE15D5C2638E343D9C71C6238AAAAAAAA97D6),
    (1, 1): (0, 0x11560BF17BAA99BC32126FCED787C88F984F87ADF7AE0C7F9A208C6B4F20A4181472AAA9CB8D555526A9FFFFFFFFC71A),
    (1, 2): (0x11560BF17BAA99BC32126FCED787C88F984F87ADF7AE0C7F9A208C6B4F20A4181472AAA9CB8D555526A9FFFFFFFFC71E,
             0x8AB05F8BDD54CDE190937E76BC3E447CC27C3D6FBD7063FCD104635A790520C0A395554E5C6AAAA9354FFFFFFFFE38D),
    (1, 3): (0x171D6541FA38CCFAED6DEA691F5FB614CB14B4E7F4E810AA22D6108F142B85757098E38D0F671C7188E2AAAAAAAA5ED1, 0),
    (2, 0): (0, 0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAA63),
    (2, 1): (0xC, 0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAA9F),
    (3, 0): (0x1530477C7AB4113B59A4C18B076D11930F7DA5D4A07F649BF54439D87D27E500FC8C25EBF8C92F6812CFC71C71C6D706,
             0x1530477C7AB4113B59A4C18B076D11930F7DA5D4A07F649BF54439D87D27E500FC8C25EBF8C92F6812CFC71C71C6D706),
    (3, 1): (0, 0x5C759507E8E333EBB5B7A9A47D7ED8532C52D39FD3A042A88B58423C50AE15D5C2638E343D9C71C6238AAAAAAAA97BE),
    (3, 2): (0x11560BF17BAA99BC32126FCED787C88F984F87ADF7AE0C7F9A208C6B4F20A4181472AAA9CB8D555526A9FFFFFFFFC71C,
             0x8AB05F8BDD54CDE190937E76BC3E447CC27C3D6FBD7063FCD104635A790520C0A395554E5C6AAAA9354FFFFFFFFE38F),
    (3, 3): (0x124C9AD43B6CF79BFBF7043DE3811AD0761B0F37A1E26286B0E977C69AA274524E79097A56DC4BD9E1B371C71C718B10, 0),
    (4, 0): (0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFA8FB,
             0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFA8FB),
    (4, 1): (0, 0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFA9D3),
    (4, 2): (0x12, 0x1A0111EA397FE69A4B1BA7B6434BACD764774B84F38512BF6730D2A0F6B0F6241EABFFFEB153FFFFB9FEFFFFFFFFAA99),
}


def _poly(i, x, degree, monic):
    acc = ONE if monic else K[(i, degree)]
    for j in range(degree - 1, -1, -1):
        acc = add(mul(acc, x), K[(i, j)])
    return acc


def map_to_curve(u):
    """Simplified SWU onto E' (RFC 9380, section 6.6.2), then the 3-isogeny to E (appendix E.3): an affine point."""
    zu2 = mul(Z, mul(u, u))
    tv1 = add(mul(zu2, zu2), zu2)
    if tv1 == ZERO:
        x1 = mul(B_ISO, inv(mul(Z, A_ISO)))
    else:
        x1 = mul(mul(neg(B_ISO), inv(A_ISO)), add(ONE, inv(tv1)))
    gx1 = add(add(mul(mul(x1, x1), x1), mul(A_ISO, x1)), B_ISO)
    if is_square(gx1):
        x, y = x1, sqrt(gx1)
    else:
        x = mul(zu2, x1)
        y = sqrt(add(add(mul(mul(x, x), x), mul(A_ISO, x)), B_ISO))
    if sgn0(u) != sgn0(y):
        y = neg(y)
    xn, xd = _poly(1, x, 3, False), _poly(2, x, 2, True)
    yn, yd = _poly(3, x, 3, False), _poly(4, x, 3, True)
    return (mul(xn, inv(xd)), mul(y, mul(yn, inv(yd))))


# ---------------------------------------------------------------------------
# curve arithmetic, generic over Fp (ints, as (a, 0)) and Fp2, Jacobian
# ---------------------------------------------------------------------------

INF = None


def _jac(p):
    return None if p is None else (p[0], p[1], ONE)


def _aff(j):
    if j is None:
        return None
    zi = inv(j[2])
    zi2 = mul(zi, zi)
    return (mul(j[0], zi2), mul(j[1], mul(zi2, zi)))


def _dbl(j):
    if j is None or j[1] == ZERO:
        return None
    x, y, z = j
    a = mul(x, x)
    b = mul(y, y)
    c = mul(b, b)
    d = mul((2, 0), sub(mul(add(x, b), add(x, b)), add(a, c)))
    e = mul((3, 0), a)
    f = mul(e, e)
    x3 = sub(f, mul((2, 0), d))
    y3 = sub(mul(e, sub(d, x3)), mul((8, 0), c))
    z3 = mul((2, 0), mul(y, z))
    return (x3, y3, z3)


def _add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    z1z1 = mul(p[2], p[2])
    z2z2 = mul(q[2], q[2])
    u1 = mul(p[0], z2z2)
    u2 = mul(q[0], z1z1)
    s1 = mul(p[1], mul(q[2], z2z2))
    s2 = mul(q[1], mul(p[2], z1z1))
    if u1 == u2:
        return _dbl(p) if s1 == s2 else None
    h = sub(u2, u1)
    i = mul((4, 0), mul(h, h))
    j = mul(h, i)
    r = mul((2, 0), sub(s2, s1))
    v = mul(u1, i)
    x3 = sub(sub(mul(r, r), j), mul((2, 0), v))
    y3 = sub(mul(r, sub(v, x3)), mul((2, 0), mul(s1, j)))
    zz = add(p[2], q[2])
    z3 = mul(sub(sub(mul(zz, zz), z1z1), z2z2), h)
    return (x3, y3, z3)


def scalar_mul(k, p):
    acc, base = None, _jac(p)
    while k:
        if k & 1:
            acc = _add(acc, base)
        base = _dbl(base)
        k >>= 1
    return _aff(acc)


def point_add(p, q):
    return _aff(_add(_jac(p), _jac(q)))


def hash_to_g2(msg, dst=DST):
    u0, u1 = hash_to_field(msg, dst)
    return scalar_mul(H_EFF, point_add(map_to_curve(u0), map_to_curve(u1)))


# ---------------------------------------------------------------------------
# keys, signatures and their encodings (zkcrypto's `bls12_381`: big-endian, flags in the top three bits)
# ---------------------------------------------------------------------------

G1 = ((G1X, 0), (G1Y, 0))


def _be(n):
    return n.to_bytes(48, "big")


def _largest(y):
    """zkcrypto's `lexicographically_largest` on Fp2: `c1`, or `c0` when `c1` is zero, above `(p - 1) / 2`."""
    half = (P - 1) // 2
    return y[1] > half or (y[1] == 0 and y[0] > half)


def public_key(sk):
    """The compressed G1 key (48 bytes) and its uncompressed point (96 bytes)."""
    x, y = scalar_mul(sk % R, G1)
    flag = 0x80 | (0x20 if y[0] > (P - 1) // 2 else 0)
    compressed = bytearray(_be(x[0]))
    compressed[0] |= flag
    return bytes(compressed), _be(x[0]) + _be(y[0])


def decompress_g1(compressed):
    """The uncompressed point (96 bytes) of a compressed G1 key."""
    assert compressed[0] & 0x80 and not compressed[0] & 0x40
    x = int.from_bytes(bytes([compressed[0] & 0x1F]) + compressed[1:], "big")
    y = sqrt_fp((x * x * x + 4) % P)
    assert y is not None, "not on the curve"
    if (y > (P - 1) // 2) != bool(compressed[0] & 0x20):
        y = P - y
    return _be(x) + _be(y)


def sign(sk, msg):
    """A compressed G2 signature (96 bytes): `sk * H(msg)`."""
    x, y = scalar_mul(sk % R, hash_to_g2(msg))
    out = bytearray(_be(x[1]) + _be(x[0]))
    out[0] |= 0x80 | (0x20 if _largest(y) else 0)
    return bytes(out)


def test_key(i):
    """The SYNTHETIC fixture's secret key `i`: `sha256("xindex.aptos.test-key" ++ u32be(i))` reduced mod r."""
    return int.from_bytes(hashlib.sha256(b"xindex.aptos.test-key" + i.to_bytes(4, "big")).digest(), "big") % R


def _check():
    assert (G1Y * G1Y - G1X ** 3 - 4) % P == 0
    assert scalar_mul(R, G1) is None
    quux = b"QUUX-V01-CS02-with-BLS12381G2_XMD:SHA-256_SSWU_RO_"
    vectors = {
        b"": (
            (0x0141EBFBDCA40EB85B87142E130AB689C673CF60F1A3E98D69335266F30D9B8D4AC44C1038E9DCDD5393FAF5C41FB78A,
             0x05CB8437535E20ECFFAEF7752BADDF98034139C38452458BAEEFAB379BA13DFF5BF5DD71B72418717047F5B0F37DA03D),
            (0x0503921D7F6A12805E72940B963C0CF3471C7B2A524950CA195D11062EE75EC076DAF2D4BC358C4B190C0C98064FDD92,
             0x12424AC32561493F3FE3C260708A12B7C620E7BE00099A974E259DDC7D1F6395C3C811CDD19F1E8DBF3E9ECFDCBAB8D6),
        ),
        b"abc": (
            (0x02C2D18E033B960562AAE3CAB37A27CE00D80CCD5BA4B7FE0E7A210245129DBEC7780CCC7954725F4168AFF2787776E6,
             0x139CDDBCCDC5E91B9623EFD38C49F81A6F83F175E80B06FC374DE9EB4B41DFE4CA3A230ED250FBE3A2ACF73A41177FD8),
            (0x1787327B68159716A37440985269CF584BCB1E621D3A7202BE6EA05C4CFE244AEB197642555A0645FB87BF7466B2BA48,
             0x00AA65DAE3C8D732D10ECD2C50F8A1BAF3001578F71C694E03866E9F3D49AC1E1CE70DD94A733534F106D4CEC0EDDD16),
        ),
    }
    for msg, point in vectors.items():
        assert hash_to_g2(msg, quux) == point, msg


_check()
