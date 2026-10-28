# cubi

A small robot that lives in the MacBook notch and keeps an eye on your Claude Code sessions:
one Cubi per session, each with its own colour. It shows what the session is doing, lets you
Allow / Deny permission requests and answer questions from the notch, shows plan usage, and
looks tired when the context window is almost full.

Status: Phase 0 (recording real hook payloads). See `docs/plan.md` once it lands.

## Build

Requires macOS 15+ and Xcode Command Line Tools. No Xcode.app needed.

```
make build        # debug
make release      # release binaries in .build/release/
make test
```
