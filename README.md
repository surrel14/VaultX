# VaultX

VaultX is an iOS/iPadOS encrypted-file vault project designed around Apple's File Provider architecture, with a long-term goal of interoperability with Cryptomator vaults.

> **Current status: v0.2.0 — local encrypted vault MVP**

## What works now

- SwiftUI iPhone/iPad application, iOS 16+
- Random 256-bit master key per vault, wrapped with a PBKDF2-HMAC-SHA256 password key
- AES-GCM authenticated encryption for vault data; encrypted vault manifest
- Folders inside a vault: create, browse, rename, move, delete (with confirmation and best-effort secure overwrite)
- Multi-file import, open (Quick Look: images, PDF, video, documents) and export (share sheet / Save to Files)
- In-RAM thumbnails for images and PDFs (never written to disk)
- Sorting (name / date / size / kind) and per-folder search
- Auto-lock: when the app goes to the background (immediately or after a delay) and after inactivity
- Face ID / Touch ID unlock via the Keychain (opt-in per vault, `biometryCurrentSet`)
- Master key kept in a zeroable buffer and wiped on lock; plaintext temp copies are overwritten and deleted
- Privacy cover in the app switcher while a vault is open
- Unit tests for key wrapping, encryption, tamper detection and vault operations
- GitHub Actions build pipeline

## Security model

The user's password is **not** used directly to encrypt every file.

1. VaultX generates a random 256-bit master key.
2. A password-derived key is generated with PBKDF2-HMAC-SHA256 and a random salt.
3. The master key is wrapped with AES-GCM using that password-derived key.
4. Files and the manifest are encrypted with the random master key.
5. Optional Face ID / Touch ID unlock stores the master key in the device Keychain protected by `biometryCurrentSet` and `ThisDeviceOnly`.
6. On lock the in-memory key is zeroed (`memset_s`) and temporary plaintext copies are removed.

The v0.2 format is intentionally **not Cryptomator-compatible yet**.

### Known limitations

- File and folder **names are not encrypted yet** (they are visible on disk, as is the folder structure); contents are.
- Files are encrypted/decrypted as a whole in memory: very large files may exhaust RAM (streaming is planned for v0.4).
- "Secure delete" overwrites files before removing them, but on APFS/flash storage this cannot guarantee physical erasure; the real protection is encryption.
- The File Provider extension is still a scaffold and is not connected to the vaults.

## Repository layout

```text
VaultX/
├── .github/workflows/ios.yml
├── VaultX/                  # Main iOS application
│   ├── Core/Crypto/
│   ├── Core/Security/
│   ├── Core/Vault/
│   └── Views/
├── VaultXFileProvider/      # File Provider extension foundation
├── VaultXTests/
├── project.yml              # XcodeGen project definition
├── ROADMAP.md
└── CONTRIBUTING.md
```

## GitHub Actions

The workflow runs on GitHub-hosted macOS runners and:

1. selects the latest installed Xcode;
2. installs XcodeGen;
3. generates `VaultX.xcodeproj`;
4. builds the iOS target without code signing;
5. runs the unit tests on an iOS Simulator.

For App Store/TestFlight distribution, signing credentials and the Apple Developer identifiers still need to be configured in your repository and Apple Developer account.

## Local development

Install XcodeGen and generate the project:

```bash
brew install xcodegen
xcodegen generate
open VaultX.xcodeproj
```

## Important before using on a real device

Replace the placeholder identifiers in `project.yml` and both entitlement files:

```text
com.example.VaultX
group.com.example.VaultX
```

with identifiers registered to your Apple Developer account.

## Roadmap

See [ROADMAP.md](ROADMAP.md).
