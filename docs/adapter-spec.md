# Adapter specification (draft)

Adapters translate a site's media and collection behavior into ClipBox's shared core model.

Goals: make simple adapters declarative where possible, complex adapters implement a small interface, and both styles easy for AI coding agents to create and validate.

Conceptual capabilities:

```text
match(url)
authenticate(context)
scan_collection(collection, cursor)
extract_media(url)
list_formats(media)
```

Simple sites may eventually use external profiles. Documentation examples must use synthetic domains such as `media.example.invalid`; real private hostnames belong only in the external user-data profile directory.

Intended AI workflow:

1. `clipbox adapter init <name>` creates a private scaffold outside the repository.
2. The user asks an AI agent to implement support for an authorized site.
3. The agent edits only that external private adapter/profile.
4. `clipbox adapter test <name>` validates extraction using redacted diagnostics.
5. `clipbox adapter doctor <name>` reports missing capabilities without printing secrets/private URLs by default.
