# Contributing

Thanks for improving Atomic Clock.

## Before submitting a change

1. Open an issue before starting a large behavior or interface change.
2. Keep the app dependency-free unless a new dependency has a clear benefit and
   a compatible license.
3. Do not commit Apple signing identities, provisioning profiles, API keys,
   `.env` files, Xcode user data, or build output. Put your team and bundle
   identifier in the ignored `Config/Signing.local.xcconfig` file as described
   in the README.
4. Preserve the Elastic License 2.0 terms. Distributed modified copies must
   include the notices required by that license.

## Validate your change

Build the app and run the unit tests from Xcode with
**Product > Build** and **Product > Test**. Equivalent Terminal commands are
documented in [README.md](README.md#build-and-test-from-terminal).

For changes to synchronization behavior, test both successful replies and
timeouts. For interface changes, check light mode, dark mode, Dynamic Type, and
VoiceOver labels on a physical device when possible.

## Pull requests

Describe what changed, why it changed, and how you tested it. Keep unrelated
changes in separate pull requests and add tests for behavior that can be
verified without live network access.
