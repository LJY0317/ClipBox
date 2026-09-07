# Agent instructions

These rules apply to AI coding agents working on the public ClipBox repository.

## Privacy boundary

- Never add a user's private/custom site hostname, URL, selector, endpoint, account identifier, cookie, token, session value, download history, or personal storage path to this repository.
- Private/custom adapters and profiles belong in ClipBox's OS user-data directory, outside the Git checkout.
- Use reserved example domains such as `example.invalid` in docs, tests, examples, and fixtures.
- Do not copy private runtime logs or diagnostic output into issues, tests, docs, or commits without redaction.
- Run `tools/privacy_check.py --staged` before committing and `tools/prepublish_audit.sh` before publishing.

## Architecture

- Keep download, archive, format-selection, and adapter logic in the shared core.
- CLI and GUI are first-class frontends; neither should duplicate download logic.
- Treat `site + canonical media ID` as archive identity when a platform exposes a stable ID.
- Do not use a local file's current presence as the sole indication that media was already downloaded.
- Preserve archive migration and import/export portability.

## Development

- Prefer small, testable changes.
- Preserve existing user changes and avoid unrelated rewrites.
- Add tests for filename normalization, archive identity, import/export, and adapter behavior as those modules are implemented.
- Public adapter examples must not require personal credentials.
- Do not add generated downloads, history exports, databases, cookies, logs, or local configuration to Git.
