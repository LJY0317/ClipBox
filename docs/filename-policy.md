# Filename policy

ClipBox's default filenames favor human readability while the archive database retains canonical identities independently.

Spaces are allowed and are the default. Modern desktop filesystems handle them reliably, and the CLI must use safe path handling instead of forcing shell-oriented filenames on users.

Underscores are used when present in source metadata or when replacing characters unsafe across supported operating systems. Title words are not converted to underscores by default.

Planned defaults:

```text
{title} [{video_id}].{ext}
@{creator} {date} [{post_id}] [{media_id}] [{width}x{height}].{ext}
{title} [{media_id}].{ext}
```

Filename policy is configurable. Duplicate detection is based on the archive database, not the filename.
