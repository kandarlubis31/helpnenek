# helpnenek

> *Kirim Foto* — a one-button photo backup for a relative who cannot be asked to manage files.

A small Flutter app that takes every photo on the phone and pushes it to a Dropbox account,
remembering what it already sent so nothing is uploaded twice. A companion Dart script on the
family computer drains that Dropbox folder into a local directory, so the storage never fills up.

Built for the situation where the person holding the phone should not have to think about it:
open the app, one button, done.

## The problem

An elderly relative takes photos constantly but never backs them up, has a phone with almost no
free space, and cannot be walked through a cloud app over the phone. Anything requiring a login
screen, a folder picker or a sync toggle will not survive contact with reality.

## How it works

1. The app asks for photo access and enumerates the device library with `photo_manager`.
2. Every photo not already in its sent-list is uploaded to Dropbox over the HTTP API.
3. Successful uploads are recorded in `SharedPreferences` (`sent_files`), so re-running the app
   only sends what is new.
4. On the family computer, `tool/dropbox_receiver.dart` polls the Dropbox app folder every 10
   seconds, downloads each file into `received_photos/`, then **deletes it from Dropbox** — the
   folder stays small and never runs into a quota.

The UI reports live counters (`sent`, `skipped`, `failed`) and the name of the file in flight,
with a distinct state for each phase: checking, permission needed, sending, done, error.

## Requirements

- Flutter 3.x / Dart 3.11
- Android (the photo library APIs used here are Android-first)
- A Dropbox app with an access token

## Build

The token is injected at compile time, never stored in the repository:

```bash
flutter build apk --release --dart-define=DROPBOX_TOKEN=sl.xxx
```

Handling Android 14's partial photo access is built in — the app detects limited access and
reports it instead of silently uploading a subset.

## Receive on the computer

Uses the Dart SDK that already ships with Flutter, so nothing else to install:

```bash
dart run tool/dropbox_receiver.dart --token sl.xxx
# or
DROPDB_TOKEN=sl.xxx dart run tool/dropbox_receiver.dart
```

Files land in `received_photos/` next to the working directory. Leave it running; new photos are
picked up automatically.

## Structure

```
lib/main.dart                    app, permission flow, upload loop, progress UI
tool/dropbox_receiver.dart       desktop poller: download then delete from Dropbox
android/                         Android runner (package com.example.backup_foto)
test/widget_test.dart
```

## Notes

- The Dropbox token is compiled into the APK. Anyone with the APK can extract it — treat it as a
  scoped, revocable credential, not a secret.
- Uploads are sequential by design. Parallelism would make the progress display useless and
  trigger rate limits on a slow connection.
- There is no delta sync: the sent-list is append-only, so re-installing the app causes one full
  re-upload.

## License

MIT
