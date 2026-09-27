# Contributing

Public adapters belong in this repository only when their implementation and tests can be shared without exposing personal account data or private site configuration.

Personal/custom adapters should be developed in ClipBox's external user-data directory and loaded through the adapter interface. Examples and fixtures must use reserved placeholder domains such as `example.invalid`.

Before committing:

1. Run relevant tests.
2. Run `python3 tools/privacy_check.py --staged`.
3. Confirm `git status` contains only intended public project files.

Before the first public push or a release, run `tools/prepublish_audit.sh`.
