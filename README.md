# bizflow

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

## M-Pesa message detection

On Android, the app requests SMS permission and listens for incoming M-Pesa or
Safaricom messages. It records supported confirmed money movements and keeps
the fee, wallet balance, and Fuliza balance as separate fields. Failed or
declined transactions, reversal cancellations, promotional messages, and
Jumbe notifications without a wallet balance are ignored. Captured messages
are held locally until the app syncs them into its transaction database.

## Finance tracking

The app stores its finance transactions, cash scans, and daily totals in
`bizflow_finance.db` using SQLite. The Android SMS receiver writes recognized
messages locally before forwarding them to Flutter; queued messages are synced
when Flutter becomes available. Duplicate M-Pesa transaction codes are ignored.

Daily summary notifications update one notification rather than creating a
stack. The cash scanner uses on-device text recognition (and the included
currency model when available), saves the captured image in app storage, and
lets the user confirm an amount, add a note, and record income or an expense.
The yearly report reads monthly totals from `daily_summaries` and renders
income, expenses, and savings in green, red, and blue.

Build the Android release APK with:

```shell
flutter pub get
flutter build apk
```

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
