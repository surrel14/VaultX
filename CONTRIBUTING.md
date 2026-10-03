# Contributing to VaultX

## Development rules

- Never invent cryptographic primitives or encryption modes.
- Keep encryption operations behind `VaultCrypto`.
- Never log passwords, master keys, plaintext file contents or Keychain data.
- Do not commit Apple signing certificates, provisioning profiles, API keys or secrets.
- Add tests for every cryptographic or vault-format change.
- Prefer atomic file writes.
- Keep the File Provider extension and main app compatible with the same App Group.

## Pull requests

A pull request should include:

1. a clear description of the change;
2. tests for security-sensitive behavior;
3. notes about any migration or vault-format impact;
4. no credentials or private user data.

Changes to the vault format must update the format version and migration strategy rather than silently changing existing files.
