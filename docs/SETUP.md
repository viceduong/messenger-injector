# Setup Guide — iPhone 13 Pro · iOS 15.6.1

## Prerequisites

- [x] iPhone 13 Pro running iOS 15.6.1
- [x] TrollStore installed and working
- [x] Facebook Messenger installed
- [ ] TrollFools IPA (included: `TrollFools_4.3-253.tipa`)
- [ ] MI Helper IPA (build via GitHub Actions or local Mac)
- [ ] MessengerInjector dylib (build via GitHub Actions or local Mac)

## Step 1: Install TrollFools

1. Transfer `TrollFools_4.3-253.tipa` to the iPhone (AirDrop / Files app)
2. Open **TrollStore** → tap the `.tipa` file → **Install**
3. Open TrollFools from the home screen
4. Verify Messenger appears in the app list

## Step 2: Build the Artifacts

### Via GitHub Actions (recommended, no Mac needed)

1. Create a **public** GitHub repo (e.g. `messenger-injector`)
2. Push this project:
   ```bash
   cd messenger-injector
   git init
   git add .
   git commit -m "Initial: dylib + helper app + CI"
   git remote add origin git@github.com:YOURUSER/messenger-injector.git
   git push -u origin main
   ```
3. GitHub Actions auto-triggers on push to `main`
4. Wait ~2 minutes for the build
5. Go to **Actions** tab → click the run → download the `messenger-injector-build` artifact
6. Unzip the artifact. You get:
   - `libMessengerInjector.dylib`
   - `MIHelper_1.0.ipa`
7. Transfer both files to the iPhone

### Via local Mac

```bash
# On a Mac with Xcode 13+
chmod +x scripts/build_all.sh
./scripts/build_all.sh
# Artifacts in dist/
# AirDrop dist/libMessengerInjector.dylib and dist/MIHelper_1.0.ipa to iPhone
```

## Step 3: Install MI Helper

1. Transfer `MIHelper_1.0.ipa` to the iPhone
2. Open **TrollStore** → tap the IPA → **Install**
3. Open **MI Helper** from the home screen
4. You should see the form (thread ID, message, send button)
5. Status label should say "Waiting for dylib..." (dylib not injected yet)

## Step 4: Inject Dylib into Messenger

1. Open **TrollFools**
2. Find **Messenger** in the app list
3. Tap **Inject** (or the `+` button)
4. A file picker opens → navigate to `libMessengerInjector.dylib`
5. Select it
6. TrollFools will:
   - Patch the dylib reference into Messenger's main binary
   - Copy the dylib into the app bundle
   - Re-sign the modified app
7. Wait for "Completed" message
8. **Force-quit Messenger** (app switcher → swipe away)
9. Reopen Messenger

## Step 5: Verify

1. Open the **Console** app on the iPhone (or use Mac's Console.app with iPhone connected)
2. Filter for `MI`
3. You should see:
   ```
   [MI] Loaded and ready. Listening for 'com.messenger.injector.send' and 'com.messenger.injector.dump'
   ```
4. Open **MI Helper** — status should change to "✅ Dylib ready"

## Step 6: Send a Test Message

1. In **MI Helper**:
   - Enter a **thread ID** (a friend's Facebook user ID for 1-on-1)
   - Enter a **test message** (e.g. "hello from injector")
   - Make sure **Group chat** is OFF
2. Tap **Send Message**
3. Watch what happens:
   - Messenger opens (or comes to foreground)
   - The target chat opens
   - After ~2.5 seconds, the message is typed into the input
   - After ~0.5 more seconds, the send button is tapped
   - The message appears in the chat

### If it doesn't work

1. Check Console for `[MI]` logs
2. Look for:
   - `[MI] No input control found` → the view hierarchy search missed the input. Use **Dump** to find the correct class name.
   - `[MI] No send control found` → same for the send button
   - `[MI] ERROR: openURL failed` → the deep link didn't work. Verify the thread ID.
3. If you need to adjust the view-finding code:
   - Edit `dylib/MessengerInjector.m`
   - Add the specific class names from the dump to `MI_findInputControl()` / `MI_findSendControl()`
   - Rebuild → re-inject via TrollFools

## Step 7: Finding Thread IDs

### 1-on-1 chats

The thread ID is the other person's **Facebook user ID** (a number).

Methods to find it:
1. Open the chat in Messenger → tap their profile picture → look at the URL
2. Use the **Dump** button in MI Helper while the chat is open → search the dump for `threadKey` or `userId`
3. Check their Facebook profile URL: `facebook.com/profile.php?id=123456789` → the ID is `123456789`

### Group chats

The thread ID is the group's **fbId**.

Methods:
1. Share the group chat → copy the link → it contains the fbId
2. Use **Dump** while the group chat is open → search for `threadFbId`
3. The deep link format is `fb-messenger://group-thread/{fbId}`

## Maintenance

### After Messenger updates

```
TrollFools → Messenger → Inject → select dylib → force-quit Messenger → reopen
```

### After iOS updates

TrollStore survives most iOS updates on 15.x. If you update past 16.6.1,
TrollStore 1.x stops working. You'd need TrollStore 2 (different install method).

### Updating the dylib

1. Edit `dylib/MessengerInjector.m`
2. Rebuild (GitHub Actions or local)
3. Transfer new dylib to iPhone
4. TrollFools → Messenger → Inject → select new dylib
5. Force-quit and reopen Messenger

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `[MI]` logs in Console | Dylib not loaded | Re-inject via TrollFools. Verify dylib is arm64. |
| `[MI] No input control found` | LightSpeed uses custom views | Dump hierarchy → find input class → add to `MI_findInputControl()` |
| `[MI] No send control found` | Send button is custom | Dump hierarchy → find send class → add to `MI_findSendControl()` |
| Chat opens but wrong chat | Wrong thread ID | Verify the ID. For 1-on-1 it's the numeric user ID. |
| Message typed but not sent | Send button heuristic missed | Adjust scoring in `MI_findSendControl()`. Or target by class name. |
| Messenger crashes on launch | Signing issue | Rebuild dylib. Ensure `codesign -f -s -` was run. Re-inject. |
| `fb-messenger://` doesn't open | Messenger not registered | Open Messenger manually once. Then retry. |
| MI Helper shows "Waiting for dylib..." | Dylib not loaded yet | Open Messenger first. Wait 3 seconds. Check Console. |
| Build fails on GitHub Actions | SDK mismatch | Check workflow logs. Ensure `macos-14` runner. |