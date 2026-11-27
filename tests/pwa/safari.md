# Mobile Safari offline smoke test

The `SecureMesh PWA iPhone Safari simulator` workflow builds the allowlisted PWA
on Linux and transfers it with checksums to the macOS runner. Apple’s WebDriver
targets an iPhone simulator by UDID. The test does not contact a SecureMesh
account server or use service credentials. Its temporary TLS CA is trusted
only by the disposable simulator and the test server only listens on loopback.

The test waits for the app's service worker to cache the bundle, disables
network delivery from the fixture, then creates a local profile through the
packaged UI. It checks the real WASM identity fingerprint, locks the profile,
reloads the page offline, rejects a wrong password, and verifies that the
original fingerprint reappears after the correct password unlocks the vault.

To run with an existing packaged bundle on a Mac with Xcode and an available
iPhone simulator runtime:

```sh
tests/pwa/safari.sh /path/to/securemesh-pwa
```

For a local engine check with an existing Playwright installation:

```sh
python3 tests/pwa/safari.py /path/to/securemesh-pwa --desktop-engine webkit
```

The WebKit engine check does not use Apple's iOS Safari. The simulator test
covers the Safari browser tab. Home Screen installation, the installed PWA
lifecycle, and physical iPhone behavior need separate evidence.

[Apple's WebDriver simulator capabilities](https://webkit.org/blog/9395/webdriver-is-coming-to-safari-in-ios-13/)
