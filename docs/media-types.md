# Media types

ClipBox separates primary media from optional derivative/sidecar assets.

## Primary media

Built-in collection synchronization currently understands these selectable primary media types:

- Videos
- Photos
- Animated media

All three are enabled by default. The macOS Collections screen exposes them as checkboxes, while the CLI accepts a comma-separated `--media-types` list.

For X, gallery-dl is used only to enumerate the authenticated timeline and identify the best direct asset URL. Photos use the original-size image request when X/gallery-dl makes it available. Animated GIF-style X media is normally served as MP4 and ClipBox preserves that file rather than converting it to GIF.

YouTube's current built-in Liked/Watch Later collections yield video items, so selecting Photos or Animated media does not create additional YouTube files.

## Optional extras planned separately

Common download tools also expose useful secondary assets:

- audio-only extraction
- subtitles and automatic captions
- thumbnails / cover art
- description and metadata sidecars

ClipBox keeps these out of the default primary-media archive because they have different semantics. Audio-only output is a derivative of a video; subtitles, thumbnails, and metadata are sidecars. They should be individually opt-in so a single saved post does not unexpectedly expand into many files.
