# VaultX Roadmap

## v0.2 — Local encrypted vault MVP

- [x] Random per-vault master key
- [x] PBKDF2-HMAC-SHA256 password wrapping
- [x] AES-GCM authenticated encryption
- [x] Encrypted manifest
- [x] File import
- [x] Face ID Keychain unlock foundation
- [x] GitHub Actions build/test

## v0.2.5 — Local vault usability

- [x] Folders (create, browse, rename, move, delete)
- [x] Delete with confirmation and best-effort secure overwrite
- [x] Rename files
- [x] Quick Look preview, in-RAM thumbnails (images, PDF)
- [x] Export through the share sheet
- [x] Sorting and search
- [x] Auto-lock (background / inactivity) and privacy cover
- [x] Face ID / Touch ID unlock through the Keychain
- [x] Master key wiped from memory on lock
- [x] Change password, recovery key, 600k-iteration PBKDF2 for new wraps
- [x] Multi-select, import from Photos / camera / "Open in"
- [x] Format v3: encrypted names, chunked streaming, per-file keys + AAD, migration from v2
- [x] Vault export / import (`.vaultxpkg`) and duplicate
- [x] Vault profiles (icon, colour, description, size, last access)
- [x] Secure sharing of single files (`.vaultxshare`, password + expiry)
- [x] Security log
- [ ] File versions and history, retention rules
- [ ] Protected trash
- [ ] Tags, favourites, advanced search
- [ ] Integrity check
- [ ] Progress for long operations, resumable imports
- [ ] Cloud sync iPhone <-> iPad (merge-friendly index, conflict handling) and WebDAV
- [ ] Vaults stored in iCloud Drive / other Files locations (depends on sync design)

## v0.3 — File Provider

- [ ] Expose the active vault in Files.app
- [ ] Enumerate directories and files
- [ ] Read encrypted files through File Provider
- [ ] Create/rename/delete files
- [ ] Create/rename/delete directories
- [ ] Coordinate concurrent file access
- [ ] Lock and invalidate provider access when the vault is locked

## v0.4 — Production-grade local filesystem

- [ ] Stream large files instead of loading them entirely in RAM
- [ ] Atomic writes and crash recovery
- [ ] Encrypted filenames
- [ ] Metadata database
- [ ] File versioning/recovery
- [ ] Secure cache lifecycle
- [ ] Memory-safety review

## v0.5 — Cryptomator interoperability

- [ ] Implement Cryptomator vault format specification
- [ ] Masterkey file compatibility
- [ ] Directory/name encryption compatibility
- [ ] Content encryption compatibility
- [ ] Cross-test against official Cryptomator implementations
- [ ] Read existing Cryptomator vaults
- [ ] Write vaults that Cryptomator can open

## v0.6 — Cloud backends

- [ ] WebDAV
- [ ] SMB
- [ ] iCloud Drive integration strategy
- [ ] Dropbox
- [ ] Google Drive
- [ ] OneDrive

## v1.0 — Release candidate

- [ ] Security audit
- [ ] Recovery/error UX
- [ ] Localization
- [ ] Accessibility review
- [ ] Performance testing on large vaults
- [ ] App Store/TestFlight signing pipeline
- [ ] Privacy documentation
