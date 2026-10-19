# Security

Mac Thermal reads local system metrics and provides an optional, explicitly confirmed disk cleanup workflow. It does not upload telemetry, require an account, install a privileged helper, or control fans. It runs with the current user’s permissions and does not use App Sandbox.

Disk cleanup starts only after the user selects a local folder. It scans bounded file metadata without reading contents, offers no automatic selection, and moves only explicitly selected regular files to Trash after a separate review. It does not permanently delete files, empty Trash, follow symbolic links, clean all caches, or request Full Disk Access. System and known cloud locations, package contents, and version-controlled project trees are excluded. Arbitrary third-party sync folders cannot all be detected; the UI asks the user to select a non-synced local folder. File and ancestor identities are checked again before each move; changed or inaccessible items are skipped. Results distinguish moved, skipped, and failed files, and moving to Trash is never reported as reclaimed space. Candidate paths and results remain in memory and are not written to logs or uploaded.

Please do not post access tokens, private process names, personal paths, or detailed vulnerability exploits in public issues. If GitHub’s **Security → Report a vulnerability** option is available, use it. Otherwise, open an issue asking for a private contact without including sensitive details.

Only current source and release assets from this repository are supported. Check release filenames, the recorded commit and SHA-256 checksums before using a download. Checksums detect file differences; they do not replace Developer ID signing or Apple notarization. The initial release is ad-hoc signed and is not notarized.
