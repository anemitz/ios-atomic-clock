# Atomic Clock

[![iOS CI](https://github.com/anemitz/ios-atomic-clock/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/anemitz/ios-atomic-clock/actions/workflows/ci.yml)

Atomic Clock is a small SwiftUI app that displays UTC and local time adjusted by
measurements from several public Network Time Protocol (NTP) servers. It is
useful for setting a watch or comparing a device clock with network time.

The app:

- queries five NTP servers concurrently over UDP port 123;
- selects the three responses with the lowest round-trip delay;
- applies the median of those offsets to the displayed time;
- refreshes automatically every five minutes and supports pull-to-refresh; and
- has no third-party dependencies, accounts, analytics, or advertising.

## Requirements

- A Mac capable of running Xcode 16 or newer
- Xcode with iOS platform support installed
- iOS 17.0 or newer for a physical iPhone or iPad
- An Apple Account added to Xcode to install on a physical device

A paid Apple Developer Program membership is not required for personal use.
Apple's free Personal Team provisioning expires periodically, so a locally
installed build may need to be rebuilt and installed again.

## Get started

Clone this repository, then open the project:

```zsh
git clone https://github.com/anemitz/ios-atomic-clock.git
cd ios-atomic-clock
open AtomicClock.xcodeproj
```

In Xcode, select the `AtomicClock` scheme and an iPhone simulator, then click
Run or press <kbd>Command</kbd>+<kbd>R</kbd>.

The simulator is useful for checking the interface. Test on a physical device
for results that reflect the device's actual network and clock.

## Install on your iPhone or iPad

1. Open Xcode and choose **Xcode > Settings > Accounts**. Add your Apple
   Account if it is not already listed.
2. Connect your unlocked device to the Mac. Accept the **Trust This Computer**
   prompt if it appears. Xcode can use the device wirelessly after it has been
   paired.
3. Create your ignored local signing configuration:

   ```zsh
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
   open -e Config/Signing.local.xcconfig
   ```

4. Replace `com.yourname.AtomicClock` with a unique reverse-domain bundle
   identifier.
5. Replace `YOUR_TEAM_ID` with your 10-character Apple Team ID:

   - Apple Developer Program members can find it under **Membership details**
     in their [developer account](https://developer.apple.com/account).
   - For a free Personal Team, select your account under
     **Xcode > Settings > Accounts** and use **Manage Certificates** to create
     an Apple Development certificate if needed. Then run:

     ```zsh
     security find-identity -v -p codesigning
     ```

     Use the 10-character value in parentheses after the matching
     `Apple Development` identity.

6. Open `AtomicClock.xcodeproj`. Automatic signing reads your local
   configuration; avoid selecting a team in **Signing & Capabilities**, because
   doing so writes that personal value into the shared project file.
7. In the Xcode toolbar, select the `AtomicClock` scheme and your device as the
   run destination. Click Run or press <kbd>Command</kbd>+<kbd>R</kbd>.
8. If requested, enable **Developer Mode** on the device under
   **Settings > Privacy & Security > Developer Mode**, restart it, and confirm
   the prompt after it restarts. Run the app from Xcode again.

With a free Personal Team, Apple currently limits provisioning profiles to
seven days. Rebuild the app from Xcode when the installed copy expires.

Apple references:
[running an app on a physical device](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices),
[enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device),
and [Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account).

`Config/Signing.local.xcconfig` is ignored by Git. Simulator and unsigned CI
builds use the public defaults in `Config/Signing.xcconfig`, while each
contributor can use a different local team and bundle identifier.

## Build and test from Terminal

Command Line Tools alone are not sufficient; select a full Xcode installation
first if necessary:

```zsh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Build without code signing:

```zsh
xcodebuild \
  -project AtomicClock.xcodeproj \
  -scheme AtomicClock \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/AtomicClockDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the unit tests from **Product > Test** in Xcode, or substitute the name of
an installed simulator in this command:

```zsh
xcodebuild \
  -project AtomicClock.xcodeproj \
  -scheme AtomicClock \
  -destination 'platform=iOS Simulator,name=YOUR_SIMULATOR_NAME' \
  -derivedDataPath /tmp/AtomicClockTestDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Network and accuracy notes

The default servers are:

- `time.apple.com`
- `time.google.com`
- `time.cloudflare.com`
- `pool.ntp.org`
- `time.nist.gov`

Some Wi-Fi networks, VPNs, cellular providers, and firewalls block outbound UDP
port 123. The app reports each failed server request and continues when at least
one server responds.

NTP packets are not authenticated, and this app does not change the iPhone's
system clock. The displayed adjustment is a best-effort estimate intended for
human time comparison—not for security, scientific measurement, navigation,
or other safety-critical use.

## Project structure

- `AtomicClock/NetworkTimeClient.swift` builds and validates NTP packets.
- `AtomicClock/ClockSyncModel.swift` selects samples and owns synchronization
  state.
- `AtomicClock/ContentView.swift` contains the SwiftUI interface.
- `AtomicClockTests/AtomicClockTests.swift` covers packet validation and sample
  selection.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
before submitting a change.

## License

This project is source-available under the [Elastic License 2.0](LICENSE).
ELv2 permits use, modification, and redistribution subject to its limitations;
it is not an OSI-approved open-source license.
