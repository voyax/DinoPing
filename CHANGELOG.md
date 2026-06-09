# Changelog

All notable changes to DinoPing are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com), and the project aims
to follow [Semantic Versioning](https://semver.org).

## [Unreleased]

## [0.1.0] — 2026-06-04
### Added
- Live monitoring of Claude Code sessions in the macOS notch.
- Process-liveness session counting — the count updates within ~2–4s when an
  instance opens or closes, even without a SessionEnd hook.
- Menu-bar dropdown with per-session status; click a session to jump straight
  to its terminal tab (iTerm2, Ghostty, Terminal).
- Native per-agent permission rules; approve or deny from the notch.
- Global hot-keys (rebindable): ⌥⌘P toggle panel, ⌥⌘J jump to the waiting
  session, ⌥⌘↩ approve, ⌥⌘⌫ deny.
- Settings: launch at login, notification sounds, display selection, and
  customizable shortcuts.
