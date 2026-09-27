# Filename policy

ClipBox's default filenames favor stable source identity while the archive database remains authoritative for duplicate detection.

For X collection media, the default uses underscore-separated stable source fields with no bracket decoration. `@` is retained for the handle snapshot; it is a valid ordinary filename character on macOS, Linux, and Windows.

Planned defaults:

```text
{title} [{video_id}].{ext}
x_{immutable_user_id}_{published_date}_@{handle}_{media_id}_{width}x{height}.{ext}
{title} [{media_id}].{ext}
```

Example X files:

```text
x_2244994945_2026-09-08_@XDevelopers_9002_1280x720.mp4
x_2244994945_2026-09-08_@XDevelopers_PhotoTokenABC_2048x1365.jpg
x_2244994945_2026-09-08_@XDevelopers_AnimTokenXYZ_640x360.mp4
```

The immutable X user ID is the authoritative author identifier in the filename. The `@handle` segment is a human-readable snapshot and may change later. The Tweet/post ID is still preserved as `source_id` in the SQLite archive, but is omitted from the default filename because the per-media ID already distinguishes attachments within a post.

The date segment is the source post's publication date as reported by the extractor, not the day ClipBox downloaded it. This keeps filenames stable across re-downloads and computer migrations. The actual download timestamp remains in the SQLite archive as `downloaded_at`.

For X video variants, ClipBox prefers the native X media ID when it can derive one from the CDN URL. For photos and animated media where the extraction result does not expose a numeric X media ID, ClipBox uses the stable public CDN media token as the per-media identifier, with a post/sequence fallback only when no better identifier is available.

Filename policy is configurable. Duplicate detection is based on the archive database, not the filename.
