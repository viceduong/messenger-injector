# Messenger Injector

Inject custom messages into specific Facebook Messenger chats on iOS 15.6.1
using TrollStore + TrollFools. No jailbreak required.

**Target device:** iPhone 13 Pro (A15 Bionic, arm64e) · iOS 15.6.1

## How It Works

```
┌──────────────────────────────────────────────────────────────────┐
│  iPhone 13 Pro · iOS 15.6.1 · TrollStore                        │
│                                                                  │
│  ┌──────────────┐  distributed    ┌───────────────────────────┐  │
│  │  MI Helper   │──notification──▶│  Messenger.app            │  │
│  │  (app)       │  com.messenger. │  ┌─────────────────────┐  │  │
│  │              │  injector.send  │  │ libMessengerInject- │  │  │
│  │  User enters │  {message,     │  │ or.dylib            │  │  │
│  │  thread ID + │   threadId,    │  │ (injected via       │  │  │
│  │  message     │   isGroup}     │  │  TrollFools)        │  │  │
│  │  taps Send   │                │  │                     │  │  │
│  └──────────────┘                │  │ 1. Receives trigger │  │  │
│                                   │  │ 2. Opens chat via   │  │  │
│  ┌──────────────┐                │  │    fb-messenger://  │  │  │
│  │  TrollFools  │──injects──────▶│  │ 3. Finds input view │  │  │
│  │  (app)       │   dylib into   │  │ 4. Types message    │  │  │
│  └──────────────┘   Messenger    │  │ 5. Taps send button │  │  │
│                                   │  └─────────────────────┘  │  │
│                                   └───────────────────────────┘  │
│                                                                  │
│  Build: GitHub Actions (free M1 Mac runner, public repo)         │
│    or local Mac with Xcode (scripts/build_all.sh)                │
└──────────────────────────────────────────────────────────────────┘
```

## Components

| File | What | How to use |
|---|---|---|
| `dylib/libMessengerInjector.dylib` | Injected into Messenger | TrollFools → Messenger → Inject |
| `helper-app/MIHelper_1.0.ipa` | Trigger app | Install via TrollStore |
| `TrollFools_4.3-253.tipa` | Injection tool | Install via TrollStore |

## Quick Start

### One-time setup

1. **Install TrollFools** — open `TrollFools_4.3-253.tipa` via TrollStore
2. **Install MI Helper** — open `MIHelper_1.0.ipa` via TrollStore
3. **Inject dylib into Messenger** — open TrollFools → find Messenger → Inject → select `libMessengerInjector.dylib`
4. **Force-quit Messenger** and reopen it
5. Verify: open Console app → filter `MI` → should see `[MI] Loaded and ready`

### Sending a message

1. Open **MI Helper** app
2. Enter the **thread ID** (see below)
3. Enter the **message text**
4. Toggle **Group chat** if targeting a group
5. Tap **Send Message**
6. Messenger opens the target chat, types the message, and sends it

### Finding thread IDs

- **1-on-1 chat:** the other person's Facebook user ID (numeric). Find it by
  opening the chat in Messenger → tap their name → their profile URL contains
  the ID. Or use the **Dump** button in MI Helper while the chat is open,
  then check the view hierarchy dump for thread identifiers.
- **Group chat:** the thread's `fbId`. Visible in the group's share URL:
  `fb-messenger://group-thread/{fbId}`

### Debugging

- Tap **Dump View Hierarchy** in MI Helper while Messenger is showing a chat
- Check the dumped file via Filza or Console app
- Look for the actual input view class name and send button class name
- If the auto-detection misses them, update `MI_findInputControl()` and
  `MI_findSendControl()` in `dylib/MessengerInjector.m` with the specific
  class names, rebuild, and re-inject

## Building

### Option A: GitHub Actions (no Mac needed)

1. Create a public GitHub repo
2. Push this project to it
3. Go to Actions tab → workflow runs automatically on push
4. Download artifacts from the completed run:
   - `libMessengerInjector.dylib`
   - `MIHelper_1.0.ipa`

Uses free M1 Mac runner (`macos-14`). Build takes ~2 minutes.

### Option B: Local Mac build

```bash
chmod +x scripts/build_all.sh
./scripts/build_all.sh
# Artifacts in dist/
```

Requires Xcode 13+ with iOS SDK.

## Re-injecting After Messenger Updates

When Messenger updates from the App Store, the injected dylib is stripped:

1. Open TrollFools
2. Find Messenger → Inject → select `libMessengerInjector.dylib`
3. Force-quit and reopen Messenger

Takes ~30 seconds.

## Project Structure

```
messenger-injector/
├── README.md
├── .github/
│   └── workflows/
│       └── build.yml              # GitHub Actions CI
├── dylib/
│   └── MessengerInjector.m       # Dylib source (ObjC)
├── helper-app/
│   ├── MIHelper.m                 # Helper app source (ObjC)
│   └── Info.plist                 # App bundle metadata
├── scripts/
│   └── build_all.sh               # Local build script
├── docs/
│   └── SETUP.md                   # Detailed setup guide
└── TrollFools_4.3-253.tipa        # TrollFools installer
```

## Requirements

- iPhone 13 Pro (or any A12+ device) running iOS 15.0–16.6.1
- TrollStore installed
- Facebook Messenger installed (App Store or TrollStore)
- No jailbreak

## Protocol Reference

All IPC via `NSDistributedNotificationCenter`:

| Direction | Name | Payload |
|---|---|---|
| Helper → Dylib | `com.messenger.injector.send` | `message` (NSString), `threadId` (NSString), `isGroup` (NSNumber), `delay` (NSString, optional, default "2.5") |
| Helper → Dylib | `com.messenger.injector.dump` | *(none)* |
| Dylib → Helper | `com.messenger.injector.ready` | `dylib` (NSString), `version` (NSString) |

## License

MIT