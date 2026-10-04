"""Read-only clients for Aptos's public data, retried. Nothing here sends a transaction or holds a key.

- `rest`: a fullnode's REST API (`/v1`), JSON or BCS. It serves transactions, their infos and events, and on-chain
  resources at a version, but no ledger info's signatures and no accumulator proof.
- `backup`: Aptos Labs' public database backups on Google Cloud Storage, which `aptos node bootstrap-db` restores from
  (`aptos-labs/aptos-networks`, `mainnet/backups/gcs.yaml` and `testnet/backups/gcs.yaml`), read anonymously over
  HTTPS. Each holds every epoch-ending ledger info with its signatures (`epoch_ending_*`), and the transactions in
  ranges of a million versions, each chunk with its accumulator range proof and the ledger info it is proven under
  (`transaction_*`).
"""

import gzip
import json
import time
import urllib.parse
import urllib.request

MAINNET = "https://api.mainnet.aptoslabs.com/v1"
TESTNET = "https://api.testnet.aptoslabs.com/v1"
BUCKETS = {"mainnet": "aptos-mainnet-backup-usce1", "testnet": "aptos-testnet-backup-usce1"}
SUB_DIR = "e1"
UA = {"User-Agent": "xindex-fixtures"}


def _retry(fn):
    for attempt in range(8):
        try:
            return fn()
        except Exception:
            if attempt == 7:
                raise
            time.sleep(2 * (attempt + 1))


def rest(node, path, bcs=False):
    headers = dict(UA)
    if bcs:
        headers["Accept"] = "application/x-bcs"

    def go():
        body = urllib.request.urlopen(urllib.request.Request(node + path, headers=headers), timeout=60).read()
        return body if bcs else json.loads(body)

    return _retry(go)


def backup(handle, network="mainnet"):
    """A file of the backup, decompressed: every file there is gzipped."""
    url = "https://storage.googleapis.com/%s/%s/%s" % (BUCKETS[network], SUB_DIR, urllib.parse.quote(handle))

    def go():
        return gzip.decompress(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=300).read())

    return _retry(go)


def backup_json(handle, network="mainnet"):
    return json.loads(backup(handle, network))


def backup_metadata(network="mainnet"):
    """The backup's metadata file names."""
    base = "https://storage.googleapis.com/storage/v1/b/%s/o" % BUCKETS[network]
    names, token = [], None
    while True:
        q = {"prefix": SUB_DIR + "/metadata/", "maxResults": "1000", "fields": "items(name),nextPageToken"}
        if token:
            q["pageToken"] = token
        d = _retry(lambda: json.load(urllib.request.urlopen(base + "?" + urllib.parse.urlencode(q), timeout=60)))
        names += [i["name"][len(SUB_DIR) + 1:] for i in d.get("items", [])]
        token = d.get("nextPageToken")
        if not token:
            return names


def records(data):
    """A backup chunk's records: each a big-endian u32 length, then the record."""
    out, p = [], 0
    while p < len(data):
        n = int.from_bytes(data[p:p + 4], "big")
        out.append(data[p + 4:p + 4 + n])
        p += 4 + n
    assert p == len(data)
    return out
