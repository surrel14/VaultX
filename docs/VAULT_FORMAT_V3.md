# VaultX vault format v3

Everything is AES-256-GCM. The **master key** (32 random bytes) is the root of trust; it is
never stored in clear: it is wrapped by the password (`masterkey.vaultx`, PBKDF2-HMAC-SHA256,
600k iterations, NFC-normalised password, authenticated header) and optionally by a recovery
key (`recovery.vaultx`, HKDF).

## Layout

```
<vault>/
  masterkey.vaultx      password-wrapped master key            (VLWK03)
  recovery.vaultx       optional recovery-key-wrapped master key (VLRK01)
  vault.manifest        AES-GCM(master key) of {version, name, createdAt}   (VLTX02 envelope)
  index.vaultx          encrypted index: names, folders, sizes, dates       (VLTX02 envelope)
  index.vaultx.bak      previous version of the index
  files/
    <UUID>.vltx         one file per vault file, flat, random names         (VLTX03)
```

Nothing about names, folder structure or file types is visible on disk; only the number of files
and their approximate sizes are.

## Keys

| Key        | Derivation                                                                  |
|------------|-----------------------------------------------------------------------------|
| file key   | `HKDF-SHA256(ikm = master key, salt = file salt (32 B), info = "VaultX v3 file key")`  |
| index key  | `HKDF-SHA256(ikm = master key, salt = empty, info = "VaultX v3 index key")`            |

Every file has its own random 32-byte salt, hence its own key.

## File format (`files/<UUID>.vltx`)

```
header (39 bytes): "VLTX03" (6) | chunkSizeLog2 (1) | salt (32)
body: chunk_0 | chunk_1 | ... | chunk_n        each chunk = ciphertext || tag(16)
```

* Default chunk size is 2^16 = 64 KiB (readers accept 2^10 ... 2^24).
* All chunks except the last carry exactly `2^chunkSizeLog2` bytes of plaintext. The last one carries
  1 ... `2^chunkSizeLog2` bytes (0 only for an empty file).
* Chunk nonce (12 bytes): `0x00 * 7 || counter (UInt32, big endian) || flag`, flag = `0x01` for the last chunk.
  The flag prevents truncation, the counter prevents reordering.
* AAD of every chunk: `header || fileID` where `fileID` is the 16 raw bytes of the UUID in the file name.
  Swapping two files on disk makes both fail to open.
* Plaintext size: `n = fileSize - 39`, `chunks = ceil(n / (2^log2 + 16))`, `size = n - 16 * chunks`.

The reference implementation used to produce the test vectors is `docs/vaultx_v3_ref.py`
(Python, `cryptography` library). `VaultXTests/VaultFormatV3Tests.swift` decrypts a file produced by it.

## Index

JSON (`{"version":1,"nodes":[...]}`), encrypted with the index key (`VLTX02` envelope: random nonce,
AES-GCM). Each node: `id`, `parentID` (null = root), `name`, `isFolder`, `size`, `created`, `modified`.
Rename and move only edit the index; files on disk are never renamed.

Consistency rules:

* A file is written to `<UUID>.vltx.part`, renamed to `<UUID>.vltx`, and only then added to the index.
* A delete removes the nodes from the index first and then securely deletes the files.
* At unlock, files in `files/` that the index does not reference (interrupted import/delete) are removed,
  unless the index had to be recovered from `index.vaultx.bak`.

## Migration from v0.2

v0.2 stored plaintext names in `data/` with whole-file `VLTX02` envelopes. Migration (on request, with
confirmation) re-encrypts every file into `files/`, builds the index, writes it **last** and only then
deletes `data/`. Any failure leaves the old vault untouched.
