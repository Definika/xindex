//! Strict XDR: a byte string is exactly one canonical value of its type, or nothing. The decoder refuses trailing bytes,
//! non-zero padding, unknown arms and out-of-range lengths; writing the value back and comparing closes whatever a
//! decoder could still accept twice, so a typed value and the bytes a hash fixed are one.

use crate::Error;
use stellar_xdr::{Limits, ReadXdr, WriteXdr};

/// How deep a value may nest: SCP's quorum sets four levels, an `SCVal` a contract's own data. stellar-core's own limit
/// for XDR it reads is 500.
const DEPTH: u32 = 500;

pub fn decode<T: ReadXdr + WriteXdr>(bytes: &[u8], what: &'static str) -> Result<T, Error> {
    let value = T::from_xdr(
        bytes,
        Limits {
            depth: DEPTH,
            len: bytes.len(),
        },
    )
    .map_err(|_| Error::BadXdr(what))?;
    if encode(&value)? != bytes {
        return Err(Error::BadXdr(what));
    }
    Ok(value)
}

pub fn encode<T: WriteXdr>(value: &T) -> Result<Vec<u8>, Error> {
    value
        .to_xdr(Limits::none())
        .map_err(|_| Error::BadXdr("encode"))
}
