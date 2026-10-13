# Flutter integration example

This example depends on the SDK through a local path. Run from this directory:

```sh
flutter pub get
flutter analyze
flutter test
flutter build web --no-pub
# Optional WebAssembly target:
flutter build web --wasm --no-pub
```

The widget accepts an `E2BClient` from the host application. The default entry point
has no credentials and disables sandbox creation. The host owns and closes the
injected client. Creating a sandbox allocates a remote resource; callers should
retain the returned sandbox and terminate it when it is no longer needed.

The widget tests inject an HTTP client and check the management request and UI
result. They do not contact E2B. The Web runner is included. Real browser/mobile/desktop
network integration and mobile/desktop runners remain to be verified. Keep long-lived E2B API keys on a trusted
backend for distributed applications.
