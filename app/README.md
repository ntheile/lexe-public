# Lexe app

This directory contains the Lexe mobile app UI, which is written in
Dart+Flutter.

## Dev setup

After following these setup steps, you'll be able to test and run the Lexe app,
on device or simulator, for both Android and iOS.

We'll also default to installing our tooling in `~/.local`, so that everything
is accessible in one place.

### Android setup

We'll install Java and the Android SDKs via CLI, as it's more repeatable.

#### Install Java (via `home-manager` (nix)):

Add this to your home-manager config somewhere and then `home-manager switch`:

```nix
programs.bash.initExtra = ''
    export JAVA_HOME=${pkgs.jdk17_headless.home}
'';
```

We only export it via `JAVA_HOME` to avoid polluting our `$PATH` with Java gunk.

Sanity check:

```bash
$ $JAVA_HOME/bin/java --version
openjdk 17.0.10 2024-01-16 LTS
OpenJDK Runtime Environment Zulu17.48+15-CA (build 17.0.10+7-LTS)
OpenJDK 64-Bit Server VM Zulu17.48+15-CA (build 17.0.10+7-LTS, mixed mode, sharing)
```

#### Install Java (via `sdkman`)

If you don't have `home-manager`, you could use `sdkman`, which is like `rustup`
but for Java.

Download the `sdkman` install script:

```bash
$ cd ~/.local
$ curl --proto '=https' --tlsv1.3 -sSf "https://get.sdkman.io?rcupdate=false" > sdkman-install.sh
$ sha256sum sdkman-install.sh
419762944a301418a6c68021c5c864f54a3ce3e013571bd38da448439695f582
# If missing the sha256sum command on macOS:
$ brew install coreutils
```

Install `sdkman`:

```bash
$ export SDKMAN_DIR="$HOME/.local/sdkman"
$ chmod a+x ./sdkman-install.sh
$ ./sdkman-install.sh
```

Run the init script:

```bash
$ source ~/.local/sdkman/bin/sdkman-init.sh
```

Ensure the init script is always run at startup by adding the following lines to
your `.bashrc` or equivalent:

```bash
export SDKMAN_DIR="$HOME/.local/sdkman" # Default is ~/.sdkman
if [[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then
    source "$SDKMAN_DIR/bin/sdkman-init.sh"
fi
```

Clean up

```bash
$ rm sdkman-install.sh
```

Install the JDK. Unfortunately, the Java ecosystem is a bit more... convoluted
than the Rust ecosystem, so we have to choose a JDK "distribution" to install.

As of 2024-06-19, Android `compileSdk` v34 requires JDK v17.
See: <https://developer.android.com/build/jdks#compileSdk>.

```bash
$ sdk list java
$ sdk install java 17.0.10-zulu

# Sanity check
$ which javac
~/.local/sdkman/candidates/java/current/bin/javac
$ javac --version
javac 17.0.10
```

#### Install Android `cmdline-tools`

This step will give us the Android `sdkmanager` from the `cmdline-tools`
"package", which we'll use to actually install the Android SDKs.

You can find the latest `cmdline-tools` download links here:
<https://developer.android.com/studio#command-line-tools-only>

```bash
$ cd ~/.local/

# (Linux only) download
$ wget https://dl.google.com/android/repository/commandlinetools-linux-9123335_latest.zip -O commandlinetools.zip
$ sha256sum commandlinetools.zip
0bebf59339eaa534f4217f8aa0972d14dc49e7207be225511073c661ae01da0a

# (macOS only) download
$ brew install wget (if needed)
$ wget https://dl.google.com/android/repository/commandlinetools-mac-9123335_latest.zip -O commandlinetools.zip
$ sha256sum commandlinetools.zip
d0192807f7e1cd4a001d13bb1e5904fc287b691211648877258aa44d1fa88275

# see zip file structure
$ unzip -l commandlinetools.zip
cmdline-tools/bin/...
cmdline-tools/lib/...
cmdline-tools/...

# install into ~/.local/android/cmdline-tools/latest
$ mkdir -p android/cmdline-tools/latest
$ unzip commandlinetools.zip -d android/cmdline-tools/latest
$ mv android/cmdline-tools/latest/cmdline-tools/* android/cmdline-tools/latest/
$ rmdir android/cmdline-tools/latest/cmdline-tools
$ rm commandlinetools.zip
```

Ensure `.bashrc` contains these lines:

```bash
# Most android tools rely on $ANDROID_HOME to find the SDK
export ANDROID_HOME=$HOME/.local/android
# sdkmanager, avdmanager, ...
ANDROID_PATH=$ANDROID_HOME/cmdline-tools/latest/bin
# adb, fastboot, ...
ANDROID_PATH=$ANDROID_PATH:$ANDROID_HOME/platform-tools
if [[ ! "$PATH" == *$ANDROID_PATH* ]]; then
    export PATH="$PATH:$ANDROID_PATH"
fi
```

Finally check our install:

```bash
# reload $PATH
$ source ~/.bashrc

# sanity check
$ which sdkmanager
~/.local/android/cmdline-tools/latest/bin/sdkmanager
$ sdkmanager --version
8.0
```

#### Install android SDKs via `sdkmanager`

Let's blindly accept every license : )

```bash
$ yes | sdkmanager --licenses
```

Check out the available SDK packages

```bash
$ sdkmanager --list
add-ons;addon-google_apis-google-24
build-tools;33.0.1
cmake;3.22.1
cmdline-tools;latest
emulator
extras;android;m2repository
extras;google;auto
extras;google;google_play_services

# .. this goes on for a while
```

Install these. You may need to update the version #'s to match those set
in the `androidSdkComposition` in <./nix/pkgs/default.nix>.

```bash
$ sdkmanager --install \
    "build-tools;35.0.0" \
    "ndk;28.2.13676358" \
    "platform-tools" \
    "platforms;android-35" \
    "platforms;android-34" \
    "sources;android-35" \
    "sources;android-34"
```

Sanity check

```bash
$ adb version
Android Debug Bridge version 1.0.41
Version 35.0.1-11580240
Installed as /home/phlip9/.local/android/platform-tools/adb
Running on Linux 6.8.0-76060800daily20240311-generic (x86_64)
```

#### Update android SDKs via `sdkmanager`

```bash
$ sdkmanager --update
```

You may also have to manually update some tools by selecting the newer versions
from `sdkmanager --list --newer`.

#### (linux only) USB debugging setup

If you only plan to use Wireless debugging, you can skip this section. Otherwise
you'll need to jump through a few extra hoops on linux machines:

Add your user to the `plugdev` group:

```bash
$ sudo usermod -aG plugdev $LOGNAME
```

Install `udev` rules:

```bash
$ sudo apt install android-sdk-platform-tools-common
```

Restart your machine. `adb devices` should now pick up any connected devices.


### (macOS only) iOS setup

#### Personal signing and bundle IDs

Keep personal Apple settings out of the tracked Xcode project. Copy
`ios/Flutter/LocalSigning.xcconfig.example` to
`ios/Flutter/LocalSigning.xcconfig` and fill in your Apple team ID and bundle
IDs. The local file is ignored by Git. These overrides apply in Xcode and
Flutter, including archives, without rewriting `project.pbxproj`.

Each flavor has its own bundle ID setting (`DEV`, `DESIGN`, `STAGING`,
`PROD`). Debug, Profile, and Release use the same identity within a flavor.
Distinct IDs let different flavors coexist on a device. Changing signing
does not change the backend environment or Google OAuth configuration.

From the repository root, enable the signing guard:

```bash
git config --local core.hooksPath .githooks
./tools/verify-ios-project-env
```

If you already use a custom hooks path, integrate `.githooks/pre-commit`
into your existing hook instead of replacing it. The hook validates the
staged snapshot and never fixes or stages files automatically. Stage the
verifier, its baseline, and the shared signing setup together on first use.
CI runs the same check on macOS (the verifier uses Apple's `plutil`).

`tools/ios-project-env.json` records the reviewed signing settings for every
Xcode configuration and the shared xcconfig files. Intentional shared signing
or configuration changes must update that baseline in the same review;
personal values belong only in the ignored local file. To inspect the staged
snapshot manually, run `./tools/verify-ios-project-env --staged`.

#### (Apple Silicon only) Install Rosetta

```bash
$ sudo softwareupdate --install-rosetta --agree-to-license
```

#### Install Xcode

Either download the app directly from <https://developer.apple.com/xcode/download/>
or install it from the Mac App Store.

Once installed, run

```bash
$ sudo xcode-select \
    --switch /Applications/Xcode.app/Contents/Developer
$ sudo xcodebuild -runFirstLaunch
```

#### Install CocoaPods

From the "Sudo-less Install" section:
<https://guides.cocoapods.org/using/getting-started.html#installation>

Ensure your `.bashrc` contains something like:

```bash
export GEM_HOME=$HOME/.local/gem
GEM_BIN=$GEM_HOME/bin
if [[ ! "$PATH" == *$GEM_BIN* ]]; then
    export PATH="$PATH:$GEM_BIN"
fi
```

Re-source `.bashrc`, check that `gem` is installed

```bash
$ source ~/.bashrc
$ echo $GEM_HOME
~/.local/gem
$ gem --version
3.0.3.1
```

Install the `cocoapods` gem. This command also updates `cocoapods` if already
installed.

```bash
$ gem install cocoapods
```

Sanity check

```bash
$ pod --version
1.16.2
```

#### Ensure the iOS Simulator app works

Download the latest iOS platform (~7.5 GiB)

```bash
$ xcodebuild -downloadPlatform iOS
```

Search for "Simulator" in Spotlight and then open it. If Spotlight doesn't work,
you can open it with `open -a Simulator`. An emulated iPhone should pop up after
a minute or so.

Flutter should then pick up the simulated iPhone as an available target:

```bash
$ just flutter devices
Found 3 connected devices:

  iPhone 15 Pro Max (mobile) • D8810737-2E02-4EF5-83DA-72934A34398B • ios          •
  com.apple.CoreSimulator.SimRuntime.iOS-17-0 (simulator)

  ...
```

If this doesn't work (no iPhone shows up), try running a random sample iOS app
in Xcode -- this seems to force Xcode to actually install everything.

A quick way to do this is to create a new project based on the "App" template.
Set the "Product Name" to whatever, set the "Organization Identifier" to
whatever, then run the app by pressing the "Play" button near the top of the
screen. The app should build and the simulated iPhone should pop up on the
screen. The temporary project can then be deleted from wherever it was created
(defaults to Desktop).

### (Pop\_OS! only?) install `libstdc++-12-dev`

If you want to run flutter linux desktop apps:

```bash
$ sudo apt install libstdc++-12-dev
```

### Flutter setup

From the setup instructions online: <https://docs.flutter.dev/get-started/install>

Ensure your `.bashrc` contains something like

```bash
export FLUTTER_HOME=$HOME/.local/flutter/bin
if [[ ! "$PATH" == *$FLUTTER_HOME* ]]; then
    export PATH="$PATH:$FLUTTER_HOME"
fi
```

Re-source `.bashrc`
```bash
$ source ~/.bashrc
$ echo $FLUTTER_HOME
~/.local/flutter/bin
```

Installing `flutter` means just cloning their repo. Make sure you _don't_ do a
shallow clone (`--depth=1`); that breaks the flutter upgrades.

```bash
$ git clone \
    --branch="stable" \
    https://github.com/flutter/flutter.git \
    ~/.local/flutter
```

Check the flutter version on `pubspec.yaml` and ckeckout to the flutter tag of
specific version.

```
$ git checkout tags/3.41.9
```

Disable their pesky telemetry : )

```bash
$ flutter config --suppress-analytics --no-analytics
$ dart --disable-analytics
```

Run `flutter doctor` to check your install:

```bash
$ flutter doctor

Downloading Material fonts...                                    1,031ms
Downloading Gradle Wrapper...                                      201ms

...

[✓] Flutter (Channel beta, 3.7.0-1.5.pre, on Pop!_OS 22.04 LTS 6.0.6-76060006-generic, locale en_US.UTF-8)
[✓] Android toolchain - develop for Android devices (Android SDK version 33.0.1)
[✗] Chrome - develop for the web (Cannot find Chrome executable at google-chrome)
    ! Cannot find Chrome. Try setting CHROME_EXECUTABLE to a Chrome executable.
[✓] Linux toolchain - develop for Linux desktop
[!] Android Studio (not installed)
[✓] Connected device (1 available)
[✓] HTTP Host Availability

! Doctor found issues in 2 categories.
```

This output is from my Pop!\_OS linux desktop. Since we don't care about flutter
web (it's trash) and Android Studio is not actually necessary (I don't use it),
we're all good to go!

Now let's check that flutter picks up any connected devices or simulators. If
you have an actual Android or iOS device, make sure they have Debugging/Dev mode
turned on and are connected to your machine.

(On Android phone) To turn on debugging / dev mode, go to
Settings > About phone > Software information, then tap the Build number pane 7
times. Then, ensure that the "USB debugging" option is turned on under
Settings > Developer options.

On my Pop!\_OS linux desktop:

```bash
$ flutter devices
2 connected devices:

Pixel 5a (mobile) • android-arm64 • Android 13 (API 33)
Linux (desktop) • linux-x64 • Pop!_OS 22.04 LTS
```

On my M1 MBP:

```bash
$ flutter devices
3 connected devices:

Pixel 5a (mobile) • android-arm64 • Android 13 (API 33)
iPhone 14 Pro (mobile) • ios • iOS-16-2 (simulator)
macOS (desktop) • macos • darwin-arm64 • macOS 13.1 darwin-arm
SM N975U1 (mobile) • RF8M80RGR3J • android-arm64 • Android 12 (API 31)
```

#### Test your flutter install on a sample app

```bash
$ mkdir -p ~/flutter-test
$ cd ~/flutter-test
$ flutter create --platforms ios,android,windows,linux,macos my_app
$ cd my_app

# this should build, install, and launch the sample app on your
# phone/simulator/desktop. Trying each takes a few minutes.
$ flutter run -d pixel
$ flutter run -d "SM N975U1" # Samsung; copy the name from `flutter devices`
$ flutter run -d iphone
$ flutter run -d mac
$ flutter run -d linux

# Clean up
$ cd ~
$ rm -rf ~/flutter-test
```

#### Pull initial flutter dependencies

```bash
$ cd app/
$ flutter pub get
```

`flutter run` will also automatically run `flutter pub get` whenever the
dependencies change in `pubspec.yaml`.


### (nvim) Editor setup

For all the `nvim` chads out there using `coc.nvim`, just do:

```vim
:CocInstall coc-flutter
```

Set `"dart.showTodos": false` in your `coc-settings.json`.


## Dev workflow

To run the Lexe app in debug mode, run the following in the `app/` directory.

```bash
$ flutter run
```

While running in debug mode, you can hit `r` in the terminal window to hot
reload the UI. If you make changes any `StatefulWidget`s or other logic before
`runApp(..)`, you'll need to hot restart with `R`.

When evaluating UI performance, run the app in profiling mode. This enables just
enough debug info to be useful without slowing everything down like debug mode.

```bash
$ flutter run --profile
```

Run unit tests:

```bash
$ flutter test
```

Run integration tests on device or emulator:

```bash
$ just app::integration -d macos
$ just app::integration -d iphone
```

From the repo root, run integration tests on a headless, ephemeral Android
emulator. On Linux, the host must provide writable `/dev/kvm` acceleration.

```bash
$ nix develop .#app-android-with-emulator --command just app::integration-android
```


## Rust/Flutter FFI

The Lexe App implements some logic as native Rust code. This allows
us to share code between our backend services, lightning nodes, and mobile apps.

The native code is made available to the Flutter app via
[`flutter_rust_bridge`](https://github.com/fzyzcjy/flutter_rust_bridge) in
[`app_rs_dart/lib/ffi/ffi.dart`](../app_rs_dart/lib/ffi/ffi.dart)

[`app-rs`](../app-rs/README.md) is the Rust crate which contains the shared
interface and code.

### Regenerate the FFI bindings code

After making changes to [`app-rs/src/ffi/ffi.rs`](../app-rs/src/ffi/ffi.rs),
be sure to regenerate the Dart+Rust FFI bindings:

```bash
$ cargo run -p app-rs-codegen
```

### FFI build process

The current build process looks like this:

1. A dev or CI instance runs `just flutter run` or `just flutter build`, which
   builds the top-level `app` application.

2. Eventually, flutter will build the `app_rs_dart` dart package, which contains
   the dart-side ffi bindings and build system integrations. The top-level `app`
   package depends on this package.

2. While building `app_rs_dart`, `flutter` delegates to `gradle` (Android),
   `Xcode/CocoaPods` (iOS/macOS), `cmake` (Linux), or TODO (Windows) to build
   the native shared library.

3. Hooks are added so that during the platform build tool's build process, it
   _unconditionally_ invokes `cargo build` on the `app-rs` crate. We don't mind
   always running `cargo build` since `cargo` has good incremental compilation
   support and does nothing when no inputs have changed.

	* (Android) we hook `gradle` in
      [`android/app/build.gradle`](android/app/build.gradle), so it calls
      [`android/build_rust.sh`](android/build_rust.sh). This script uses
      [`cargo-ndk`](https://github.com/bbqsrc/cargo-ndk) under-the-hood to wrap
      the `cargo` invocation.

	* (iOS/macOS) the cocoapods package definitions in
      `app_rs_dart/{ios,macos}/app_rs_dart.podspec` contain a `script_phase`
      hook, which `xcodebuild` interprets during the build and calls the
      `app_rs_dart/build_ios_macos.sh` script. This script shells out to
      `cargo build -p app-rs` to build a _static_ library that gets linked into
      the final `app_rs_dart` _shared_ library.

	* (Linux) TODO

	* (Windows) TODO

* Flutter finishes building the `app_rs_dart` package and produces a shared
  library, like `libapp_rs_dart.so` on Android.

* The flutter build for the top-level `app` application package then bundles the
  shared library with the final application, so we can load it at runtime.

### Caveats

* Unfortunately, the hot-reload and hot-restart features for `flutter run` don't
  support reloading native libraries. If you've changed `app-rs` and want to see
  the effects, you'll need to full-restart `flutter run`.

### Lexe Connect PoC (iOS)

The PoC handles `https://zaprite.bolt12.rocks/lexe/connect` and returns to
`https://zaprite.bolt12.rocks/lexe/callback`. It supports `read_info`,
`read_payments`, `receive`, and `spend`. Spending requires explicit consent
to unlimited payments, including invoices, offers, and on-chain addresses.
There is no amount limit or renewal interval. It rejects budgets, intervals,
explicit permissions, and POST callbacks. Granted credentials remain valid
until revoked from the app's Client credentials screen.

For personal signing, copy `ios/Flutter/LocalSigning.entitlements.example`
to `ios/Flutter/LocalSigning.entitlements`, then add these local overrides:

```xcconfig
LEXE_IOS_CONNECT_DOMAIN = zaprite.bolt12.rocks
CODE_SIGN_ENTITLEMENTS = Flutter/LocalSigning.entitlements
```

Both local signing files are ignored and protected by the commit guard.
Enable Associated Domains on your Apple App ID and refresh its provisioning
profile. The deployed association must authorize your signed application
identifier for `/lexe/connect`. Zaprite's development app must separately
claim `/lexe/callback`. Changing the entitlement domain does not change the
PoC's explicit URL allowlist in `lib/connect.dart`.

#### Request and response encoding (PoC v2)

This is our local encrypted-only profile of the September 18 candidate
[protocol](https://github.com/ZapriteApp/app-to-app-authorization/blob/4064b59ead7f9b16f05ad48d84b704c3fda20bfb/lexe-connect/protocol.md).
Version 2 rejects the earlier query-response PoC. These wire choices still
need joint agreement; they are not an official version of the shared draft.

Requests require `v=2`, `request_id`, `scopes`, `redirect_uri`,
`hpke_pubkey`, `expires_at`, and `metadata`. `app_name` and `label` are
optional unverified display hints. The callback domain is the primary
identity on the approval screen. No remote branding is fetched.

- Generate 32 fresh CSPRNG bytes for confidential state in `metadata`,
  encoded as canonical unpadded base64url. Parsing checks syntax, not entropy.
- Generate an independent public `request_id` with at least 128 random bits.
  The parser accepts 22–128 URL-safe characters. It is a lookup/deduplication
  aid, never proof of origin or a replacement for secret state.
- `scopes` is a comma-separated list with no duplicates.
- `expires_at` is Unix time in seconds, at most ten minutes in the future.
  This expires the connection request, not the granted credential.
- `hpke_pubkey` is a 32-byte X25519 public key, unpadded base64url.
- Percent-encode query values once. Preserve the exact emitted URL string.

Both success and rejection callbacks preserve the existing callback query
and put only `v=2`, public `request_id`, and `credential_ciphertext` in the
fragment. Secret state is returned only inside the encrypted payload.
No plaintext result or error downgrade is permitted.

The ciphertext is unpadded base64url of `enc || ct`, where `enc` is the first
32 bytes and `ct` includes the AES-GCM authentication tag. Encryption uses
RFC 9180 base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-128-GCM
(KEM/KDF/AEAD IDs 0x0020/0x0001/0x0001). HPKE info is the UTF-8 string
`lexe-connect/v2`. AAD is the exact original request URL in UTF-8, not a
reconstructed or normalized URL. HPKE Base mode does not authenticate the
sender; keeping outbound state confidential remains essential.

The decrypted success JSON contains `v`, `outcome=success`, `request_id`,
`metadata`, `credential`, `client_pubkey`, and `scopes`. `client_pubkey`
identifies the issued client, not the user's wallet or receiving address.
Rejection contains `v`, `outcome=rejected`, `request_id`, `metadata`, and
`error=access_denied`, with no credential or scopes.

Zaprite must validate the live pending attempt, expiration, expected
response mode, and decrypted state and outcome. It must inspect the actual
granted scopes through the trusted Lexe API before accepting the connection
once and securely storing the credential. The callback's scope list is not
an independent attestation of the grant. Zaprite fetches the wallet identity
and receiving address with that same credential, then offers a review before
saving it in protected spending storage.

Invalid requests and setup failures are shown locally and never redirected.
Dismissing the screen without a decision returns no callback. A failed
return retries the same encrypted result. After an ambiguous issuance
failure or process exit, inspect Client credentials before starting again.
Only public request IDs and expirations are persisted for replay protection,
never credentials, state, or callback URLs. Opening the callback is not an
application-level receipt; there is no automatic revocation on delivery
failure. Return delivery uses an iOS Universal Link with no browser fallback.
Android recipient verification is not implemented.

#### Shared fixtures

`test/fixtures/lexe-connect-v2.json` contains a byte-exact request URL, success
and rejection JSON, callback URLs, and HPKE vectors with disposable keys.
The Rust test reproduces encryption and verifies decryption and tamper
rejection. The Dart test checks parsing and callback construction against
the same file. Zaprite's receiver should consume this fixture too.

The fixture's RNG and private key are public test material, never production
inputs. To deliberately regenerate after a protocol change:

```sh
LEXE_CONNECT_UPDATE_VECTORS=1 cargo test --locked -p app-rs \
  ffi::connect::tests::shared_wire_vectors --lib
```

Run that command from the repository root, then review and commit the vector
diff. Normal test runs only compare against the checked-in fixture.
