# Private adapter protocol v1

Private adapters are executable programs stored outside the ClipBox Git repository. ClipBox communicates with them using one JSON request on stdin and one JSON response on stdout.

The current protocol version is `1`.

> Security: protocol v1 private adapters are local executable code and are not sandboxed into a separate low-privilege account. They run with the permissions of the user launching ClipBox. Review or otherwise trust AI-generated adapter code before running it. The directory boundary described below prevents manifest path escape; it does not make arbitrary adapter code safe.

## Directory and manifest

Each adapter has a private directory containing `adapter.json` and an executable declared by that manifest.

Example using only synthetic data:

```json
{
  "protocolVersion": 1,
  "id": "example-private-adapter",
  "displayName": "Example Private Adapter",
  "executable": "adapter.py",
  "collections": [
    {
      "id": "favorites",
      "displayName": "Favorites"
    }
  ]
}
```

The executable path must be relative and remain inside the adapter directory. ClipBox resolves symlinks and rejects path traversal, absolute paths, or executable links that resolve outside that private adapter directory.

The public machine-readable manifest schema is in `schemas/private-adapter-manifest.schema.json`.

## Process rules

- Read exactly one JSON request from stdin.
- Write exactly one protocol JSON response to stdout.
- Send human diagnostics to stderr, not stdout.
- Never print cookies, tokens, passwords, session values, or authorization headers.
- Exit `0` for a syntactically valid protocol response. Use a non-zero exit code for runtime failure.
- Do not bypass DRM, paywalls, authorization controls, or other access restrictions.
- Treat browser/login access as user-authorized local access only.

ClipBox provides these environment variables to the process:

```text
CLIPBOX_PRIVATE_ADAPTER_ID
CLIPBOX_PRIVATE_ADAPTER_DIR
```

## `doctor`

Request:

```json
{
  "protocolVersion": 1,
  "command": "doctor",
  "collection": null,
  "browser": null,
  "limit": null
}
```

Response:

```json
{
  "protocolVersion": 1,
  "ok": true,
  "message": "Ready"
}
```

`doctor` should validate prerequisites that can be checked without downloading a collection. Keep the message free of secrets and private session values.

Optional request members may be omitted by the JSON encoder when they are not applicable; adapters should treat a missing optional member the same as JSON `null`.

## `scan`

Request example:

```json
{
  "protocolVersion": 1,
  "command": "scan",
  "collection": "favorites",
  "browser": "safari",
  "limit": 100
}
```

`browser` is the browser identifier selected by the user. The adapter may use it with a local tool's browser-cookie support. ClipBox does not send raw cookies through the protocol.

`limit` is the requested maximum number of newest collection entries to inspect. `null` means the user explicitly requested the full collection.

Response:

```json
{
  "protocolVersion": 1,
  "items": [
    {
      "mediaID": "stable-media-123",
      "sourceID": "post-456",
      "sourceURL": "https://media.example.invalid/watch/post-456",
      "title": "Example video",
      "creator": "ExampleCreator",
      "publishedAt": "2026-09-08T12:00:00Z",
      "extensionName": "mp4",
      "width": 1920,
      "height": 1080,
      "bitrate": 5000000,
      "download": {
        "strategy": "direct",
        "url": "https://cdn.example.invalid/media/stable-media-123.mp4"
      }
    }
  ]
}
```

### Required item fields

`mediaID` must be stable across scans. It is the durable ClipBox duplicate key inside this adapter's namespace. Do not use a temporary CDN query token as the ID when a stable site media ID exists.

`sourceURL` is the human-facing page/source URL associated with the item.

`download.strategy` and `download.url` tell ClipBox how to retrieve the media.

### Optional item fields

`sourceID` can hold a post/page ID when that differs from the media ID. This is important for posts containing multiple videos.

`title`, `creator`, `publishedAt`, `extensionName`, `width`, `height`, and `bitrate` improve filenames and archive metadata but are not required for duplicate detection.

## Download strategies

### `direct`

Use when the adapter has already resolved the final downloadable media variant. ClipBox downloads that URL with a streaming system transfer and records the adapter `mediaID` as the archive identity.

Typical uses include a selected MP4 CDN variant. The adapter should choose the best desired variant itself before returning it.

### `yt-dlp`

Use when yt-dlp can process the returned URL, including supported pages or media manifests. ClipBox passes the user's selected browser source to yt-dlp when appropriate and records the adapter `mediaID` independently of yt-dlp's internal extractor ID.

Example:

```json
{
  "mediaID": "stable-media-789",
  "sourceURL": "https://media.example.invalid/watch/stable-media-789",
  "download": {
    "strategy": "yt-dlp",
    "url": "https://media.example.invalid/watch/stable-media-789"
  }
}
```

## Archive behavior

ClipBox namespaces private adapter identities as:

```text
custom:<adapter-id> + mediaID
```

The public repository never needs to know which real site that namespace represents.

During sync ClipBox:

1. scans through the adapter,
2. compares each namespaced media ID with SQLite history,
3. records collection membership,
4. downloads only unarchived items,
5. records success/failure and output path,
6. skips the same media on future scans even if the file has moved to another drive.

## AI-agent implementation checklist

When an AI agent implements a private adapter, it should:

1. Work only in the external private adapter directory for site-specific code/data.
2. Preserve the manifest/protocol version unless ClipBox explicitly upgrades it.
3. Identify a stable media ID and separate source/post ID when necessary.
4. Enumerate the newest collection items first when the site supports ordering.
5. Respect the request `limit`; treat `null` as explicit full scan.
6. Use the selected browser only through local browser-cookie/session mechanisms.
7. Return final downloadable URLs or yt-dlp-processable URLs without bypassing DRM/access controls.
8. Keep stdout clean JSON and redact sensitive stderr diagnostics.
9. Run `clipbox adapter doctor`, then `scan`, then a `sync --dry-run` before a real sync.
