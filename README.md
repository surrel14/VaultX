# VaultX

VaultX is an iOS/iPadOS encrypted-file vault project designed around Apple's File Provider architecture, with a long-term goal of interoperability with Cryptomator vaults.

> **Current status: v0.2.0 — local encrypted vault MVP**

## What works now

- SwiftUI iPhone/iPad application
- iOS 16+
- Random 256-bit master key per vault
- Password protection using PBKDF2-HMAC-SHA256
- AES-GCM authenticated encryption for vault data
- Encrypted vault manifest
- File import into an encrypted vault
- Face ID protected Keychain unlock (when enabled and supported)
- App Group foundation for the future File Provider
- Unit tests for key wrapping, encryption and tamper detection
- GitHub Actions build and test pipeline

## Security model

The user's password is **not** used directly to encrypt every file.

1. VaultX generates a random 256-bit master key.
2. A password-derived key is generated with PBKDF2-HMAC-SHA256 and a random salt.
3. The master key is wrapped with AES-GCM using that password-derived key.
4. Files and the manifest are encrypted with the random master key.
5. Optional Face ID unlock stores the master key in the device Keychain protected by `biometryCurrentSet`.

The v0.2 format is intentionally **not Cryptomator-compatible yet**.

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
