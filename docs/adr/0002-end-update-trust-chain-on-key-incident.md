# End the update trust chain on an Ed25519 key incident

Without Developer ID, CodexRadar cannot authenticate an automatic Ed25519 key rotation after the existing private key is lost, cannot be verified, or may be compromised. The project therefore terminates the current Update Trust Chain, stops advancing the Production Feed, and requires users to install a new bootstrap release with a new key instead of attempting an automatic key rotation or unsigned fallback.
