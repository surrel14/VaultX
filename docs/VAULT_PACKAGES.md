# VaultX packages

Two single-file formats, both streamed (constant memory).

## Vault package (`.vaultxpkg`) — export / import / duplicate a whole vault

The vault is already encrypted on disk, so the package is just its folder packed into one file. It opens
with the same password as the vault (Face ID keys live in the device Keychain and are never exported).

```
"VXVAULT1" (8) | headerLength UInt32 BE | header JSON {format: 1, name, createdAt}
entry*  : 0x01 | pathLength UInt16 BE | path UTF-8 | size UInt64 BE | data | digest (32)
          digest = SHA-256(path UTF-8 | size UInt64 BE | data)
end     : 0x00 | entryCount UInt32 BE | SHA-256(digest_0 | digest_1 | ...) (32)
```

Only these top-level names are exported/imported: `masterkey.vaultx`, `recovery.vaultx`, `vault.manifest`,
`index.vaultx`, `index.vaultx.bak`, `profile.json`, `files/`, `data/`.

Import safety: paths are validated (no absolute paths, `..`, `.`, empty components, backslashes, unknown
roots, duplicates); every file is verified against its digest and the closing summary; the vault is built in a
hidden staging folder and only renamed into place when complete (a failed import leaves nothing behind); an
existing vault is never overwritten (`Name (2)`). The digests detect accidental corruption — they are not
authentication; the vault's own AES-GCM data is authenticated when it is opened.

## Protected share package (`.vaultxshare`) — one file, password, optional expiry

```
header (51 bytes, authenticated as AAD of every chunk):
  "VXSHR1" (6) | chunkSizeLog2 (1) | iterations UInt32 BE (4) | PBKDF2 salt (16)
  | package ID (16) | expiry Int64 BE, seconds since 1970, 0 = none (8)
body: AES-256-GCM chunks (same scheme as vault files: counter + last-chunk flag nonce) of the stream
  metadataLength UInt32 BE | metadata JSON {name, size, createdAt} | file bytes
key = HKDF-SHA256(PBKDF2-HMAC-SHA256(NFC(password), salt, iterations), salt: empty, info: "VaultX share key v1")
```

The file name is inside the encrypted stream. The expiry is in the authenticated header: it cannot be removed
without invalidating the package, and VaultX refuses to open an expired package. It is a courtesy, not a
guarantee: it cannot delete or disable copies that were already received.

References for the test vectors: `docs/vaultx_v3_ref.py` (vault files) and `docs/vaultx_share_ref.py`.
