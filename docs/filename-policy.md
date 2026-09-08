# Filename policy

ClipBox's default filenames favor stable source identity while the archive database remains authoritative for duplicate detection.

For X collection media, the default is intentionally shell-friendly and compact: underscore-separated source fields with no bracket decoration.

Planned defaults:

```text
{title} [{video_id}].{ext}
@{creator}_{published_date}_{post_id}_{media_id}_{width}x{height}.{ext}
{title} [{media_id}].{ext}
```

Example X files:

```text
@ExampleUser_2026-09-08_7001_9002_1280x720.mp4
@ExampleUser_2026-09-08_7001_PhotoTokenABC_2048x1365.jpg
@ExampleUser_2026-09-08_7001_AnimTokenXYZ_640x360.mp4
```

The date segment is the source post's publication date as reported by the extractor, not the day ClipBox downloaded it. This keeps filenames stable across re-downloads and computer migrations. The actual download timestamp remains in the SQLite archive as `downloaded_at`.

For X video variants, ClipBox prefers the native X media ID when it can derive one from the CDN URL. For photos and animated media where the extraction result does not expose a numeric X media ID, ClipBox uses the stable public CDN media token as the per-media identifier, with a post/sequence fallback only when no better identifier is available.

Filename policy is configurable. Duplicate detection is based on the archive database, not the filename.
