# Menu Tasks Bar

A macOS menu bar app to view and manage your **Google Tasks**. Written in Swift/SwiftUI, with no external dependencies.

- Lists, tasks and subtasks from Google Tasks, with a local cache so it opens instantly.
- Favorites and time of day (stored only on your Mac: the Google API doesn't support them).
- Pending-task counter in the icon; syncs every 30 s while the panel is open and every 5 min in the background.
- Optional launch at login.

Requires macOS 13 or later.

## Privacy and security

- Sign-in uses OAuth 2.0 + PKCE through `ASWebAuthenticationSession`. No client secret.
- Requests only the `https://www.googleapis.com/auth/tasks` scope.
- Tokens are stored in the Keychain; the task cache is a file readable only by the user (0600).
- App Sandbox with network access as its only entitlement (`Resources/TasksBar.entitlements`).
- The app only talks to Google's servers. No telemetry.

## Build

You need Xcode (or the Command Line Tools) with Swift 5.9+ and your own Google OAuth Client ID.

### 1. Create the Client ID

1. In [Google Cloud Console](https://console.cloud.google.com/) create a project and enable the **Google Tasks API**.
2. Configure the OAuth consent screen and add the `.../auth/tasks` scope.
3. Create an **OAuth client ID** of type **iOS** with the bundle ID `com.devalv.MenuTasksBar` (or your own, if you change it in `Resources/Info.plist`).
4. Download the `.plist` and save it in the repo root as `client.plist`. It is in `.gitignore`.

> While the consent screen is in "Testing" mode, only the test users you add can sign in, and tokens expire after 7 days.

### 2. (Optional) Stable signing

By default the script signs ad-hoc, so the Keychain asks for permission again after every build. To avoid that, always sign with the same certificate:

```sh
cp .env.example .env     # edit SIGN_ID with your certificate
```

`.env` is in `.gitignore`. To distribute outside your Mac you need a *Developer ID Application* certificate and, to notarize, `NOTARY_PROFILE` (see `.env.example`).

### 3. Build

```sh
./scripts/build.sh              # produces build/TasksBar.app
UNIVERSAL=1 ./scripts/build.sh  # arm64 + x86_64
```

To produce the distribution `.zip` and `.dmg`: `./scripts/package.sh` (they end up in `build/`).

`build.sh` reads `CLIENT_ID` from `client.plist` and injects it into the `.app`'s `Info.plist`; the Client ID is not in the source code.

## Development

```sh
export TASKSBAR_CLIENT_ID="your-id.apps.googleusercontent.com"   # swift run has no Info.plist
swift run
swift test
```

In debug builds, `TASKSBAR_FAKE=1 swift run` starts with demo data, without signing in or touching your real Keychain or cache.

## Reporting a vulnerability

Open a private advisory from the repository's *Security* tab instead of a public issue.

## License

[MIT](LICENSE)
