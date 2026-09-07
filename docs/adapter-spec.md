# Adapter architecture

ClipBox has two adapter classes:

1. **Built-in public adapters** ship in the repository for broadly supported services.
2. **Private adapters** live in the user's macOS Application Support directory and are intentionally outside the Git checkout.

The private adapter system is designed for AI-assisted customization. A user should not need to understand ClipBox internals in order to ask an AI coding agent to add support for a site they are authorized to access.

## Private adapter workflow

```sh
clipbox adapter init my-adapter
clipbox adapter path my-adapter
clipbox adapter doctor my-adapter
clipbox adapter scan my-adapter favorites --browser safari --limit 100
clipbox adapter sync my-adapter favorites --browser safari --dry-run
```

`adapter init` writes only to ClipBox's external user-data directory. It does not create site-specific files in the public repository.

The generated directory contains:

```text
<ClipBox Application Support>/adapters/my-adapter/
├── adapter.json
├── adapter.py
└── AGENT_INSTRUCTIONS.md
```

The scaffold is deliberately incomplete. The user can point an AI coding agent at that private directory and the public protocol document, then let the agent implement the site-specific logic locally.

See [Private adapter protocol](private-adapter-protocol.md) for the executable contract.

## Privacy boundary

Private adapter files may contain real domains, endpoints, selectors, or other site-specific implementation details because they are local runtime data. They must not be copied into this repository, public issues, fixtures, examples, or diagnostics intended for publication.

Public examples use reserved synthetic domains such as `media.example.invalid`.

## Download ownership

Private adapters enumerate and normalize media. ClipBox still owns archive history, duplicate decisions, output paths, retries, and final download status.

An adapter can choose one of two download strategies per item:

- `direct`: the adapter has already selected a final downloadable media URL, such as a progressive MP4. ClipBox transfers it without re-encoding.
- `yt-dlp`: the adapter returns a page/manifest/media URL that yt-dlp can process. ClipBox invokes yt-dlp but records the adapter's stable media ID as the archive identity.

This split lets an AI-written adapter focus on site-specific discovery without reimplementing ClipBox's durable archive behavior.
