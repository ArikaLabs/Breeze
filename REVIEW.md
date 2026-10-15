# What counts as a finding

- A token, key, account, password or device serial in code, tests, logs, docs, screenshots or commit messages.
- A protocol change without a vector, or a vector edited to match the code instead of the unit.
- A test deleted, skipped or weakened; a capability claimed in the UI that the unit did not report.
- A literal colour in a view, a border on a card or key, or a view that only reads in one theme.
- A claim in `README.md` or `site/index.html` that a unit or feature is tested when nobody linked it.
- A new network destination beyond the unit's LAN address and Midea's SmartHome login.
- Credentials written anywhere but `CredentialStore`; settings written anywhere but `AppSettings`.
