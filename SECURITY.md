# Security

ClipBox may interact with browser sessions, authenticated collections, download history, and local storage paths. These are sensitive data.

Personal/custom adapters, cookies, tokens, session material, private URLs, and history databases are designed to live outside the public Git repository.

Do not attach raw cookies, session exports, private adapter files, or unredacted diagnostic bundles to public issues.

## Private adapter trust

Private adapters are executable local code. Protocol v1 constrains the executable path to its private adapter directory, including after symlink resolution, but does not sandbox what a trusted adapter process can do after launch. A private adapter therefore runs with the permissions of the user who launched ClipBox. Review or otherwise trust adapter code, including AI-generated code, before executing it.

ClipBox is intended to work with media the user is authorized to access and that can be retrieved without bypassing DRM or other access-control mechanisms.
