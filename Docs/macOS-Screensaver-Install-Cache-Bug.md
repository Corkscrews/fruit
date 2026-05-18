# macOS Screensaver Install Cache Bug

## Problem

When replacing a `.saver` bundle in `~/Library/Screen Savers/`, macOS
continues running the old version — even after a full reboot.

Copying a freshly built `Fruit.saver` over the existing one appears to
succeed (no errors from `cp`), but the screensaver binary, version string,
and behaviour remain unchanged.

## Root Cause

Two independent caching mechanisms prevent the new binary from loading:

### 1. `legacyScreenSaver.appex` keeps the old binary in memory

On macOS Sonoma and later, screensavers run inside
`legacyScreenSaver.appex`. Once this process loads a `.saver` bundle, the
Mach-O binary stays mapped in memory. Overwriting the file on disk has no
effect on the running process, and macOS may restart the same process
(with the in-memory binary) across screensaver activations.

### 2. `cp -R` merges instead of replacing directories

`cp -R src.saver dest.saver` when `dest.saver` already exists does **not**
replace the directory — it copies `src.saver` *into* `dest.saver`, or
merges contents while leaving stale files behind. The result is that old
binaries and resources persist even though the copy appeared to succeed.

### 3. WallpaperAgent cache (Sequoia)

On macOS Sequoia, `WallpaperAgent` maintains its own screensaver cache at:

```
~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/
  com.apple.wallpaper.caches/screenSaver-/
```

This cache can survive reboots and cause the system to load stale
screensaver bundles.

## Fix

The correct replacement sequence is:

```bash
# 1. Kill the process holding the old binary
killall legacyScreenSaver 2>/dev/null || true

# 2. DELETE the old bundle — do not overwrite
rm -rf ~/Library/Screen\ Savers/Fruit.saver

# 3. Copy the fresh build
cp -R build/Fruit.saver ~/Library/Screen\ Savers/Fruit.saver

# 4. Strip quarantine so Gatekeeper does not block loading
xattr -dr com.apple.quarantine ~/Library/Screen\ Savers/Fruit.saver
```

The critical step is **rm -rf before cp**. Without it, `cp -R` merges
directories and stale binaries remain.

## Build Script

The project's build script supports `--install` to automate this:

```bash
bash .github/scripts/build.sh --install
```

This performs a clean archive build, kills `legacyScreenSaver`, removes
the old bundle, copies the new one, and strips the quarantine attribute.

## How to Verify

Compare the binary hash before and after installation:

```bash
md5 -q ~/Library/Screen\ Savers/Fruit.saver/Contents/MacOS/Fruit
```

If the hash matches the build output, the replacement succeeded. If it
matches the previous install, the stale cache is still active — re-run
the full replacement sequence above.

## Affected Versions

- macOS Sonoma 14.x (`legacyScreenSaver.appex` caching)
- macOS Sequoia 15.x (`WallpaperAgent` cache, `legacyScreenSaver.appex`)
