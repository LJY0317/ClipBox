# X browser sessions: findings and design

Research checked on 2026-09-08. Recommendations below are engineering choices for a free, personal macOS app using its owner's existing access. They are not a promise that X's undocumented interfaces will remain available.

## A. Safari: readable database does not imply a usable X session

Verified in gallery-dl 1.32.11 and the inspected GitHub master mirror: Safari extraction opens `~/Library/Cookies/Cookies.binarycookies` first. It tries the Safari container's `Library/Cookies/Cookies.binarycookies` only if the first path does not exist. It does not merge stores or search Safari profiles; its WebKit loader ignores the profile argument. Consequently, an old readable first file can mask another store. A successful cookie count is not an authentication test. [Source](https://github.com/mikf/gallery-dl/blob/v1.32.11/gallery_dl/cookies.py).

Apple confirms Safari 17+ profiles isolate cookies and website data. Private browsing and other WebKit applications can also use different data stores. The exact active store on an individual Mac must be established separately; ClipBox limits discovery to Safari’s own known store directories; it does not scan other applications’ WebKit containers or copy cookie files. [Apple profiles](https://support.apple.com/en-us/105100).

Safari 18.4 added opt-in partitioned cookies (CHIPS), chiefly for third-party contexts. This does **not** establish that X moved its first-party authentication into partitioned cookies or IndexedDB. No primary-source evidence checked here establishes such an X-specific migration. Profile/store mismatch, an obsolete file, private-window state, and writes not yet persisted are hypotheses; missing `auth_token` in the extracted store is the directly observed failure. [WebKit networking changes](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/).

The inspected yt-dlp Safari extractor accepts an explicit binary-cookie file path. That is not automatic discovery of a named Safari profile, nor support for every WebKit database format. gallery-dl does not provide equivalent path selection through its Safari profile argument. [yt-dlp source](https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/yt_dlp/cookies.py). The familiar Safari permission issue is about a denied read; it is a different failure from reading a store with no X cookies. [Issue 7392](https://github.com/yt-dlp/yt-dlp/issues/7392).

## B–C. Recommended free authentication

The checked stable releases are gallery-dl **1.32.11 (September 4)** and yt-dlp **2026.08.19**. Both were already installed during this investigation. gallery-dl's release page says active development moved to Codeberg; follow its linked upstream for subsequent changes. [gallery-dl release](https://github.com/mikf/gallery-dl/releases/tag/v1.32.11), [yt-dlp release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19).

| Method | Practical behavior | ClipBox policy |
| --- | --- | --- |
| Chrome / Brave / Firefox session | Normal browser login; select the exact profile; reread when a job starts | Primary method |
| Browser without explicit profile | Upstream may select the most recently used cookie database, which can belong to another account | Convenience only; prefer a verified explicit profile |
| Firefox container | Select the container as well as the profile; avoid mixing all containers | Advanced field |
| Safari session | Existing support works only when the selected legacy store contains the session | Best effort |
| `cookies.txt` | Widely supported but plaintext, export burden, stale session risk | Not enabled by default |
| Manually supplied session cookies | Authentication secret can be copied, leaked or invalidated | Do not put values in command arguments/config files |

Browser-cookie authentication is explicitly supported by the tools, including Chromium, Firefox and Safari. yt-dlp recommends browser extraction as the easiest cookie input. This supports choosing the approach; it does not guarantee uninterrupted access to X. [gallery-dl authentication](https://github.com/mikf/gallery-dl#authentication), [yt-dlp FAQ](https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp).

The X extractor uses `auth_token` as its authentication cookie and `ct0` for CSRF. It can generate a CSRF token when absent and update it from responses, so missing `ct0` alone must not be a hard connection failure. It implements Likes and Bookmarks through X's web endpoints and says username/password login is no longer supported. Let the extractor manage those details. A successful empty response does not prove that an entered Likes handle belongs to the signed-in account. [X extractor](https://github.com/mikf/gallery-dl/blob/v1.32.11/gallery_dl/extractor/twitter.py).

## D–E. Native connection UX

Current implementation:

1. Enumerate known browser profile directories without reading cookie values.
2. Let the user choose the browser and explicit profile, open X in that browser, and check that its active profile matches. Opening a URL does not guarantee the browser selects the intended profile.
3. “Test connection” makes a bounded authenticated Bookmarks request and, when supplied, a Likes request. “Find X sessions” checks discovered profiles sequentially after a button click; it does not silently probe accounts at app launch or switch accounts after a failure.
4. Show per-profile success or actionable failure, with no raw server response or cookie values.
5. Remember only the verified profile and optional handle in local preferences. “Forget” removes them.

Cookie names/presence booleans are appropriate diagnostic inputs but are not sufficient to label a connection successful. Treat even account/profile labels as private when exporting diagnostics. The current checker reports actual endpoint results instead of implementing a second cookie parser in Swift.

Chrome may request access to **Chrome Safe Storage** through macOS `security`. This is the browser encryption key, not the user's X password; its capability is broader than a single site's cookies. Explain the expected prompt and let the user approve it in macOS. Do not instruct users to grant permanent access automatically. Firefox avoids this particular Chrome decryption prompt. [gallery-dl cookie implementation](https://github.com/mikf/gallery-dl/blob/v1.32.11/gallery_dl/cookies.py).

## F–I. Storage, fallbacks and ownership

Recommended order:

1. **Explicit Chrome/Firefox/Brave profile + gallery-dl**. One process per combined X job; cookie values remain inside the extractor. Direct media downloads use the extracted URL; yt-dlp/ffmpeg remain media fallbacks where needed.
2. **Another signed-in browser profile** if extraction fails. This is the currently implemented fallback and preserves browser-managed session expiry/revocation.
3. **Optional Keychain session**, only if a demonstrated UX need justifies maintaining a second session copy. This is a proposed extension, not implemented. Use Keychain item APIs, local non-synchronizing storage, explicit connect/disconnect, expiration testing, and an in-memory pipe to the adapter. Never move the secret into argv, environment variables, logs, SQLite or preferences. Browser logout does not necessarily delete the copied Keychain item. Keychain protects storage but does not make an expired token valid. [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services).
4. **Manual cookies.txt**, advanced opt-in only. It conflicts with the default no-plaintext-export principle. If ever added, clearly explain that limitation, disable tool cookie-file updates and avoid backups/logging. Do not automatically export every site's cookies.

A site-scoped browser extension with native messaging could avoid raw browser database access, but adds installation, permissions, signing and browser maintenance. An app-owned WKWebView login creates another session and does not inherit Safari's login; login compatibility is not assured. Browser DOM automation is heavier and more fragile for bulk collection traversal. None is a clear universal improvement over the established extractor route under these constraints.

Keep X GraphQL endpoints, query IDs, transaction headers and CSRF handling in gallery-dl. Keep collection/media normalization, deduplication, download state, retry policy and native UX in Swift. This reduces duplicated reverse-engineering work while retaining a replaceable adapter boundary. Pin/test supported tool releases and check upstream when authentication changes. The release mirror is not a service-level guarantee.

## J. Execution and synchronization details

Implemented: argument arrays (no shell interpolation), configuration isolation for X, no cookie export, no persistent gallery-dl cache, domain-scoped Chrome/Firefox selection, concurrent memory pipes, bounded output, async process cancellation and timeouts, sequential collection requests, 1–2 second request delays, bounded HTTP/API retries, and explicit rate-limit errors. Normal bounded X Preview now requests one real timeline page at a time and keeps the continuation cursor only in process memory; the user explicitly requests each additional page and Sync can reuse the loaded pages. The user can stop a scan/download; completed media remains archived.

Rate limits are variable. gallery-dl supports waiting for the reset or aborting; bounded scans abort and ask for a later retry. Full scans allow gallery-dl to wait for resets, with a visible explanation and a Stop button (six-hour process ceiling). A future resumable worker should surface reset/Retry-After countdowns, persist pagination progress, and avoid retrying expired credentials. “15 minutes” in guidance is approximate, not a guaranteed reset time. [Configuration](https://github.com/mikf/gallery-dl/blob/v1.32.11/docs/configuration.rst).

Use an initial full traversal and periodic reconciliation. Do not use tweet publication date as a collection checkpoint: an old tweet can be newly liked/bookmarked. A scan of the newest 100 posts cannot guarantee discovery of 101 new entries. Membership currently records observed inclusion, not confirmed current inclusion/removal. Files remain deduplicated by site/media ID across Likes and Bookmarks. Membership writes are now isolated by server-verified X user ID; legacy rows remain in an `unknown` namespace and are never silently attributed to the current account. A failed collection scan fails the batch and does not claim completion; durable pagination cursor resume remains future work.

The app is currently a locally packaged, unsandboxed development app. Child processes inherit sandbox restrictions in a sandboxed distribution; Full Disk Access does not remove App Sandbox restrictions, and Terminal approval does not prove the GUI has access. Test the signed/notarized GUI itself. A future App Store design needs a different, explicitly permitted data-access route. [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox).

“Runtime cookies” is not a claim of zero secret bytes ever reaching disk: the browser persists its own session; an upstream cookie reader can make temporary database copies; OS paging/crash reporting is outside this policy. ClipBox itself does not create plaintext cookie files. Diagnostics must use an allowlist of statuses, counts, versions and timings, never raw HTTP/debug output.

## Scan observations and Safari store selection

ClipBox now persists scan scope (all/newest count, source, selected X collections and media types). Preview records its actual scope and time so changing controls cannot relabel an old result. Local `scans/` files retain the latest and previous snapshots per browser route, entered handle and scan scope, with mode 0600. They contain collection membership, returned order among discovered media posts, original post links and dates, but no direct media URLs, cookies, cursor values or session tokens. Comparison uses membership IDs and never interprets a missing result as deletion. Before an X scan/sync, ClipBox performs a separate minimal identity check and uses a server-verified user ID for membership isolation when available; a non-dry-run X sync refuses to write membership/download changes when that identity cannot be server-verified.

Preview separates collection order, supports loading the next X page from the existing cursor, links to original posts and checks a pasted post URL against the current result. `date_bookmarked` is preserved as a gallery-dl-derived date; no exact like timestamp is invented. Publication date and bookmark date are distinct. Paged browsing is intentionally transient rather than a durable cursor checkpoint; periodic full reconciliation remains separate. Comparison only applies to identical completed scan settings and cannot certify complete site coverage.

The X timeline response already includes the media poster/image URL needed for a representative thumbnail. The bridge derives a small `pbs.twimg.com` thumbnail URL from that response instead of opening each post. Thumbnail pixels are fetched separately only for rows SwiftUI brings into view, using an ephemeral cookie-free session, a memory-only cache and a small per-host connection limit. Thumbnail URLs are not written to scan snapshots or the archive database. This adds small CDN image transfers but no additional X timeline/post-detail API request.

For Python-based gallery-dl installations with an absolute Python shebang (including the tested Homebrew package), an in-memory bridge observes successful Likes/Bookmarks page calls. Its output contains only collection kind, page/entry counts and a coarse final response condition (missing/repeated cursor, empty page, unrecognized response or interrupted-with-cursor). Endpoint URLs, request/response bodies and cursor values are not logged. Internal hooks remain version-sensitive and are isolated in `GalleryBridge.swift`; other executable formats retain ordinary extraction without these diagnostics. A repeated cursor can be an ordinary end-of-list response and is not proof that older records exist.

The same bridge can select a Safari `Cookies.binarycookies` file explicitly. Discovery checks legacy defaults and Safari’s own `WebKit/WebsiteDataStore/*/Cookies/Cookies.binarycookies` stores. When SafariTabs contains a real profile record (`type=1`, `subtype=2`), ClipBox matches that record's `external_uuid` to the WebsiteDataStore UUID and displays Safari's profile title. Ordinary tab/page titles are never used for this mapping; unmatched stores are numbered as unidentified stores instead of exposing UUID fragments. The displayed profile name is still separate from X account identity. Reads are runtime only. On the development Mac, Terminal could enumerate the protected Safari stores while the repeatedly rebuilt ad-hoc-signed ClipBox GUI was denied enumeration. After switching the installed app to a persistent local self-signed code-signing identity, the GUI enumerated five readable Safari stores; the installed GUI then server-verified the selected X session and completed a one-item Bookmarks Preview. A controlled second binary with a different CDHash but the same certificate-based designated requirement retained the same access without another privacy-setting change. This demonstrates the signing/privacy identity issue on that Mac, but does not prove that every Safari access failure is caused by code signing. The installed app still reports permission denial separately from a readable Safari profile that simply lacks an X login. Formats not understood by gallery-dl still require another connection route; this is not universal Safari profile support. No Safari extension is required for this tested path.

For repeated local development installs, `tools/setup-local-signing.sh` can create `ClipBox Local Development Code Signing`, a self-signed root/code-signing identity stored in the user's login Keychain. The trust entry is user-scoped and constrained to the `codeSign` policy. `tools/package-app.sh` automatically uses that identity when present and fails if an explicitly requested signing identity is unavailable. This is an internal-development mechanism only; it is not a substitute for Developer ID signing/notarization for distributed builds.
