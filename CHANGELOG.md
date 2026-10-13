## 0.1.0

- Initial pure Dart SDK for E2B sandbox lifecycle and pagination.
- Connect JSON command execution, background handles, stdin, PTY and filesystem watch.
- Binary/text file upload and download, filesystem metadata and directory operations.
- Injectable HTTP client, typed errors, protocol tests and Dart VM/web examples.

## Unreleased — full JS parity work

- Add Dockerfile RUN/COPY heredoc conversion, shebang scripts, tab stripping and literal command-substitution handling with official converter vectors.

- Port the pinned Moby Docker ignore matcher and add upstream pattern tables, including Windows and Unicode cases.

- Add batch file writes, gzip upload paths for VM/Web, metadata validation and envd feature gating.

- Add Secrets and Volume resource clients with typed metadata, isolated content tokens, and streaming file transfers.
- Add snapshot listing/deletion, per-fork results, filesystem-only pause/snapshots and reboot-on-resume.
- Add IAM token placeholders, network selector/transform callbacks, proxy config and dynamic updates.
- Add file URL signatures, MCP helpers, per-call connection overrides, environment defaults, management retries and cancellation.
- Record the pinned upstream method inventory and outstanding parity requirements in docs/PARITY.md.

- API alignment: response objects use `TemplateBuildStatusResponse`; `TemplateBuildStatus` now represents the string state. Migrate old `TemplateBuildStatus({...})` construction to `TemplateBuildStatusResponse({...})`.

- Add Sandbox static creation, connection, listing, fork and management methods.
  Instance `fork()` now returns Sandbox or E2BException items; migrate wrapper-based access.
- Fix Sandbox reconnect resource reassignment and align health endpoint errors.
- Embed a licensed internal HTTP/2 transport fork for canceled-stream late headers,
  connection credit, padded DATA and empty DATA fixes; keep hosted http2 for test servers.
- Exclude test TLS fixtures, development tools and work documents from published archives.

- Require Dart >=3.5.4: Dart 3.4 lacks the native connection-task factory used by proxy transport.
- Add Template static build/management and Volume static management entries; static Volume create/connect own a client released with close().
- Honor cancellation while buffering browser/multipart upload inputs.
- Fix native multipart Content-Type/boundary loss by finalizing requests before copying transport headers.
- Add independent Flutter example/CI, Web JavaScript/Wasm builds, real Chrome network checks and macOS arm64 local protocol validation tools.
