# ClipBox

ClipBox is an open-source media download and archive toolkit designed around a shared core with CLI and GUI frontends.

Its core idea is simple: download media once, remember it permanently, and keep that history portable even when the files themselves move to external storage.

## Principles

- One shared core for CLI, GUI, and future local/web interfaces.
- Incremental sync: skip media already archived, even if the files are no longer on the current computer.
- Portable download-history backup and restore between computers.
- User-selectable download destinations, defaulting to the operating system's Downloads folder under `ClipBox/`.
- Public adapters may live in this repository; personal/custom site adapters and profiles must live outside the repository.
- Cookies, session material, personal download history, private site URLs, and private adapters are never intended to be committed.
- AI-agent-friendly adapter specifications and machine-readable CLI output are first-class design goals.

## Planned interfaces

- `clipbox` CLI for people, scripts, and AI agents.
- Desktop GUI for interactive use.
- Local web UI after the core and desktop workflow are stable.
- Hosted web functionality may be considered later for public URL downloads only.

See [ROADMAP.md](ROADMAP.md) for planned implementation phases.

## License

MIT. See [LICENSE](LICENSE).
