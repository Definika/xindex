//! RLP read in place, as `RlpReader.sol` reads it: an item is its payload, a slice of the bytes that hold it, and
//! whether it is a list. Every item is checked to lie inside the one that holds it, so a malformed encoding fails
//! rather than being read past its end.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Item<'a> {
    pub payload: &'a [u8],
    pub is_list: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BadRlp;

const SHORT_STRING: u8 = 0x80;
const LONG_STRING: u8 = 0xb8;
const SHORT_LIST: u8 = 0xc0;
const LONG_LIST: u8 = 0xf8;

/// The item at the start of `data`, and the bytes after it.
fn decode(data: &[u8]) -> Result<(Item<'_>, &[u8]), BadRlp> {
    let prefix = *data.first().ok_or(BadRlp)?;
    let (start, len, is_list) = if prefix < SHORT_STRING {
        (0, 1, false)
    } else if prefix < LONG_STRING {
        (1, (prefix - SHORT_STRING) as usize, false)
    } else if prefix < SHORT_LIST {
        let n = (prefix - LONG_STRING + 1) as usize;
        (1 + n, length(data.get(1..1 + n).ok_or(BadRlp)?)?, false)
    } else if prefix < LONG_LIST {
        (1, (prefix - SHORT_LIST) as usize, true)
    } else {
        let n = (prefix - LONG_LIST + 1) as usize;
        (1 + n, length(data.get(1..1 + n).ok_or(BadRlp)?)?, true)
    };
    let end = start.checked_add(len).ok_or(BadRlp)?;
    let payload = data.get(start..end).ok_or(BadRlp)?;
    Ok((Item { payload, is_list }, &data[end..]))
}

/// A long item's length: one to eight big-endian bytes.
fn length(bytes: &[u8]) -> Result<usize, BadRlp> {
    let mut v: u64 = 0;
    for b in bytes {
        v = (v << 8) | u64::from(*b);
    }
    usize::try_from(v).map_err(|_| BadRlp)
}

/// The item `data` encodes, which must span all of `data`.
pub fn to_item(data: &[u8]) -> Result<Item<'_>, BadRlp> {
    let (item, rest) = decode(data)?;
    if !rest.is_empty() {
        return Err(BadRlp);
    }
    Ok(item)
}

impl<'a> Item<'a> {
    /// The number of items in a list. Each is decoded in place and none is kept, so a list of any length reads in
    /// constant memory: a Solana program's heap is 32 KiB and never frees (LG-1).
    pub fn count(&self) -> Result<usize, BadRlp> {
        if !self.is_list {
            return Err(BadRlp);
        }
        let mut n = 0;
        let mut rest = self.payload;
        while !rest.is_empty() {
            rest = decode(rest)?.1;
            n += 1;
        }
        Ok(n)
    }

    /// The `index`-th item of a list, after skipping the items before it in place.
    pub fn at(&self, index: usize) -> Result<Item<'a>, BadRlp> {
        if !self.is_list {
            return Err(BadRlp);
        }
        let mut rest = self.payload;
        for _ in 0..index {
            rest = decode(rest)?.1;
        }
        Ok(decode(rest)?.0)
    }

    /// A string's bytes.
    pub fn bytes(&self) -> Result<&'a [u8], BadRlp> {
        if self.is_list {
            return Err(BadRlp);
        }
        Ok(self.payload)
    }

    /// A 32-byte string.
    pub fn bytes32(&self) -> Result<[u8; 32], BadRlp> {
        self.bytes()?.try_into().map_err(|_| BadRlp)
    }

    /// A string of at most 32 bytes as a big-endian number, which must fit 64 bits.
    pub fn uint(&self) -> Result<u64, BadRlp> {
        let b = self.bytes()?;
        if b.len() > 32 {
            return Err(BadRlp);
        }
        let split = b.len().saturating_sub(8);
        if b[..split].iter().any(|x| *x != 0) {
            return Err(BadRlp);
        }
        Ok(b[split..]
            .iter()
            .fold(0u64, |v, x| (v << 8) | u64::from(*x)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_every_form() {
        // A byte, a short string, a long string, a short list, a long list.
        assert_eq!(
            to_item(&[0x05]).unwrap(),
            Item {
                payload: &[0x05],
                is_list: false
            }
        );
        assert_eq!(to_item(&[0x82, 1, 2]).unwrap().payload, &[1, 2]);
        let long = [&[0xb8, 56][..], &[7u8; 56]].concat();
        assert_eq!(to_item(&long).unwrap().payload.len(), 56);
        let list = to_item(&[0xc3, 0x01, 0x81, 0x80]).unwrap();
        assert_eq!(list.count().unwrap(), 2);
        assert_eq!(list.at(0).unwrap().uint().unwrap(), 1);
        assert_eq!(list.at(1).unwrap().uint().unwrap(), 0x80);
        let long_list = [&[0xf8, 56][..], &[0x01; 56]].concat();
        assert_eq!(to_item(&long_list).unwrap().count().unwrap(), 56);
        assert_eq!(to_item(&[0xc0]).unwrap().count().unwrap(), 0);
        assert_eq!(to_item(&[0x80]).unwrap().uint().unwrap(), 0);
    }

    #[test]
    fn refuses_what_runs_past_its_end() {
        assert_eq!(to_item(&[]), Err(BadRlp));
        assert_eq!(to_item(&[0x82, 1]), Err(BadRlp));
        assert_eq!(to_item(&[0xb9, 0x01]), Err(BadRlp));
        assert_eq!(to_item(&[0xc2, 0x82, 1]).unwrap().count(), Err(BadRlp));
        assert_eq!(to_item(&[0xc2, 0x82, 1]).unwrap().at(0), Err(BadRlp));
        assert_eq!(
            to_item(&[0xc3, 0x01, 0x81, 0x80]).unwrap().at(2),
            Err(BadRlp),
            "past the last item"
        );
        assert_eq!(to_item(&[0x01, 0x02]), Err(BadRlp), "trailing bytes");
        assert_eq!(
            to_item(&[0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
            Err(BadRlp)
        );
        assert_eq!(
            to_item(&[0x81, 0x01]).unwrap().count(),
            Err(BadRlp),
            "a string is no list"
        );
        assert_eq!(to_item(&[0x81, 0x01]).unwrap().at(0), Err(BadRlp));
        assert_eq!(
            to_item(&[0xc0]).unwrap().bytes(),
            Err(BadRlp),
            "a list is no string"
        );
        assert_eq!(to_item(&[0x82, 1, 2]).unwrap().bytes32(), Err(BadRlp));
        let wide = [&[0x89][..], &[1u8; 9]].concat();
        assert_eq!(to_item(&wide).unwrap().uint(), Err(BadRlp), "past 64 bits");
        let padded = [&[0xa1][..], &[0u8; 33]].concat();
        assert_eq!(
            to_item(&padded).unwrap().uint(),
            Err(BadRlp),
            "past 32 bytes"
        );
    }
}
