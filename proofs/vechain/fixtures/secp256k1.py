"""secp256k1 in pure Python, for the synthetic fixture only: test keys, signing and recovery, as go-ethereum's
`crypto.Sign` and `crypto.SigToPub` use the curve (`r ++ s ++ v`, `v` the recovery id, `s` low). Slow and not
constant-time: never for a real key."""

import hashlib

from keccak import keccak

P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def _add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0]:
        if (p[1] + q[1]) % P == 0:
            return None
        lam = 3 * p[0] * p[0] * pow(2 * p[1], -1, P) % P
    else:
        lam = (q[1] - p[1]) * pow(q[0] - p[0], -1, P) % P
    x = (lam * lam - p[0] - q[0]) % P
    return (x, (lam * (p[0] - x) - p[1]) % P)


def _mul(k, p=G):
    r = None
    while k:
        if k & 1:
            r = _add(r, p)
        p = _add(p, p)
        k >>= 1
    return r


def test_key(label):
    """A test key derived from a label: never a real one."""
    return int.from_bytes(hashlib.sha256(b"xindex vechain synthetic key " + label).digest(), "big") % N


def address(d):
    q = _mul(d)
    return keccak(q[0].to_bytes(32, "big") + q[1].to_bytes(32, "big"))[12:]


def sign(d, digest):
    """`r ++ s ++ v` over a 32-byte digest, low `s`, deterministic nonce."""
    z = int.from_bytes(digest, "big")
    k = int.from_bytes(hashlib.sha256(d.to_bytes(32, "big") + digest).digest(), "big") % N
    while True:
        r_point = _mul(k)
        r = r_point[0] % N
        s = pow(k, -1, N) * (z + r * d) % N
        if r and s:
            break
        k = (k + 1) % N
    v = r_point[1] & 1
    if r_point[0] >= N:
        v |= 2
    if s > N // 2:
        s = N - s
        v ^= 1
    return r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([v])


def recover(digest, sig):
    """The address that signed `digest`, from `r ++ s ++ v`."""
    r, s, v = int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:64], "big"), sig[64]
    x = r + (N if v & 2 else 0)
    y2 = (pow(x, 3, P) + 7) % P
    y = pow(y2, (P + 1) // 4, P)
    if (y & 1) != (v & 1):
        y = P - y
    z = int.from_bytes(digest, "big")
    rinv = pow(r, -1, N)
    q = _add(_mul(s * rinv % N, (x, y)), _mul((-z * rinv) % N))
    return keccak(q[0].to_bytes(32, "big") + q[1].to_bytes(32, "big"))[12:]
