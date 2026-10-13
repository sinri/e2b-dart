# Third-party notices

`lib/src/dockerignore.dart` adapts the Apache-2.0 PatternMatcher implementation in
`e2b-dev/E2B/packages/dockerfile-utils-js/src/dockerignore.ts`, commit
`df6c368152b067512702fc677952c0fc4e13c2f0`, authored by FoundryLabs, Inc.
That implementation is derived from `moby/patternmatcher` (Apache-2.0).
The Dart adaptation changes syntax and integrates E2B's TemplateException.
The heredoc marker parsing in `lib/src/dockerfile_heredoc.dart` also adapts the Apache-2.0 Dockerfile syntax helper from that package.
The extracted test vectors retain the upstream test cases.
The Apache License 2.0 is included in `LICENSE-APACHE-2.0`.

The main E2B JS SDK is MIT-licensed; its license is preserved in `LICENSE`.

`lib/src/shell_lex.dart` adapts the same pinned package's Apache-2.0
`lexer.ts`, derived from BuildKit. `test/fixtures/buildkit/shell` retains its
BuildKit shell test vectors; their provenance is recorded in the adjacent README.

`lib/src/mcp_generated.dart` is generated from the pinned E2B MIT-licensed
`spec/mcp-server.json`; `tool/generate_mcp_types.py` records the source commit.

`lib/src/vendor/http2` contains the Dart project's `http2` 2.3.1 sources under
its BSD license, with retained source copyright headers, `LICENSE`, and `AUTHORS`.
Original file hashes and origin are recorded in `UPSTREAM.json`. Local changes
handle canceled-stream HEADERS, ignored DATA credit, DATA padding, and empty
DATA; details are in its README. The unmodified hosted package is used only as
a development dependency for independent server interoperability tests.
