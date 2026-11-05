# Release packaging

Run the release packager from the repository root:

```sh
./scripts/package-release.sh 1.0.0
```

The script performs a clean Release build with Xcode automatic signing disabled. After Xcode finishes copying the application resources, it applies a complete bundle-level ad-hoc signature with the hardened-runtime option. Packaging stops unless `codesign --verify --deep --strict` succeeds.

The script then creates a compressed DMG containing `macro-pad.app` and an Applications alias, verifies the disk image, mounts it read-only, and independently runs strict signature verification against the packaged application. It prints the final size and SHA-256 checksum only after all checks pass.

The packager refuses to overwrite an existing DMG. Move or archive an older artifact explicitly before rebuilding the same version.

## Distribution status

Ad-hoc signing only seals the bundle so macOS can verify that its code and resources have not changed since packaging. It is not Apple Developer ID signing and does not establish the developer's identity. The DMG and application are not notarized, so Gatekeeper restrictions may still apply on other Macs.
