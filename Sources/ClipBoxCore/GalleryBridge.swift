import Foundation

struct CollectionPageState: Sendable, Equatable {
    let collection: String
    let nextCursor: String?
}

/// Observations only: never log URLs, cursor values, response bodies or authentication data.
public struct CollectionDiagnostic: Codable, Equatable, Sendable {
    public let collection: String
    public let pages: Int
    public let entries: Int
    public let lastPageEntries: Int
    public let stop: String
    public var stopDescription: String {
        switch stop {
        case "no_next_cursor": "Site returned no next cursor; full coverage unverified"
        case "repeated_cursor": "Site repeated its cursor"
        case "empty_page_with_cursor": "Empty page with a continuation cursor"
        case "stopped_with_next_cursor": "Stopped while a next cursor was available (limit or interruption)"
        case "request_failed_or_cancelled": "Request failed or was cancelled"
        case "unrecognized_response": "Response structure not recognized"
        default: "Termination reason unavailable"
        }
    }
}

enum GalleryBridge {
    static func interpreter(for executable: URL) -> URL? {
        guard let file = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 512),
              let first = String(data: bytes, encoding: .utf8)?.components(separatedBy: .newlines).first,
              first.hasPrefix("#!/"), !first.contains("/env ") else { return nil }
        let path = String(first.dropFirst(2))
        guard !path.contains(" "), URL(fileURLWithPath: path).lastPathComponent.hasPrefix("python"),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func diagnostics(_ stderr: String) -> [CollectionDiagnostic] {
        stderr.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("CLIPBOX_SCAN ") else { return nil }
            return try? JSONDecoder().decode(CollectionDiagnostic.self, from: Data(line.dropFirst(13).utf8))
        }
    }

    /// Pagination cursors are process-memory state only. They are parsed from the
    /// bridge control channel and must never be copied into diagnostics or logs.
    static func pageStates(_ stderr: String) -> [CollectionPageState] {
        stderr.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("CLIPBOX_PAGESTATE "),
                  let data = line.dropFirst(18).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let collection = object["collection"] as? String else { return nil }
            return CollectionPageState(collection: collection, nextCursor: object["nextCursor"] as? String)
        }
    }

    static func stderrWithoutPrivatePageState(_ stderr: String) -> String {
        stderr.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("CLIPBOX_PAGESTATE ") }
            .joined(separator: "\n")
    }

    // Runs in the installed gallery-dl interpreter. Its internal hooks are isolated here;
    // X endpoints and pagination remain owned by gallery-dl. No persistent cookie cache.
    static let script = #"""
import sys, json, atexit, os, copy, re, urllib.parse
from gallery_dl import cookies
from gallery_dl.extractor import twitter

store = sys.argv.pop(1)
if store:
    if os.path.basename(store) != 'Cookies.binarycookies':
        raise SystemExit('Unsupported Safari cookie file')
    cookies._safari_cookies_database = lambda: open(store, 'rb')

try:
    bridge_options = json.loads(sys.stdin.read() or '{}')
except Exception:
    bridge_options = {}
page_mode = bool(bridge_options.get('pageMode'))
resume_cursors = bridge_options.get('cursors') or {}
expected_owner = bridge_options.get('expectedOwnerID')

original_init_cursor = twitter.TwitterExtractor._init_cursor
def init_cursor(self):
    key = 'Likes' if self.subcategory == 'likes' else ('Bookmarks' if self.subcategory == 'bookmark' else None)
    if key and key in resume_cursors:
        return resume_cursors[key]
    return original_init_cursor(self)
twitter.TwitterLikesExtractor._init_cursor = init_cursor
twitter.TwitterBookmarkExtractor._init_cursor = init_cursor

def small_thumbnail(url):
    if not isinstance(url, str) or not url.startswith('https://pbs.twimg.com/'):
        return url
    head = url.split('?', 1)[0]
    base, dot, ext = head.rpartition('.')
    if dot and ext and '/' not in ext:
        return base + '?format=' + ext + '&name=small'
    return url

# The timeline response already contains a poster/media image URL. Preserve one
# representative small-image URL per post in output metadata without making an
# additional X timeline or post-detail request.
original_extract_files = twitter.TwitterExtractor._extract_files
def extract_files(self, data, tweet):
    files = original_extract_files(self, data, tweet)
    try:
        media = data.get('extended_entities', {}).get('media') or ()
        thumbnail = next((m.get('media_url_https') or m.get('media_url') for m in media
                          if m.get('media_url_https') or m.get('media_url')), None)
        thumbnail = small_thumbnail(thumbnail)
        if thumbnail:
            for file in files:
                file.setdefault('clipbox_thumbnail', thumbnail)
    except Exception:
        pass
    return files
twitter.TwitterExtractor._extract_files = extract_files

observations = {}
page_state = {}
terminators = {}
original_call = twitter.TwitterAPI._call
def without_instructions(value):
    value = copy.deepcopy(value)
    def walk(node):
        if isinstance(node, dict):
            for key in list(node):
                if key == 'instructions' and isinstance(node[key], list):
                    node[key] = []
                else:
                    walk(node[key])
        elif isinstance(node, list):
            for child in node: walk(child)
    walk(value)
    return value

def call(self, endpoint, params, *args, **kwargs):
    kind = endpoint.rsplit('/', 1)[-1]
    if kind not in ('Likes', 'Bookmarks'):
        return original_call(self, endpoint, params, *args, **kwargs)
    if expected_owner:
        try:
            twid = self.extractor.cookies.get('twid', domain=self.extractor.cookies_domain)
            decoded = urllib.parse.unquote(twid or '').strip('"')
            match = re.search(r'(?:^|&)u=(\d+)(?:&|$)', decoded)
            if not match or match.group(1) != str(expected_owner):
                raise RuntimeError('CLIPBOX_ACCOUNT_CHANGED')
        except RuntimeError:
            raise
        except Exception:
            raise RuntimeError('CLIPBOX_ACCOUNT_CHANGED')
    if page_mode and kind in terminators:
        # End this extractor after exactly one real server page. gallery-dl sees
        # a normal empty-instructions response, while no second network call is made.
        return terminators[kind]
    stat = observations.setdefault(kind, dict(collection=kind, pages=0, entries=0,
        lastPageEntries=0, stop='interrupted_or_error'))
    try:
        data = original_call(self, endpoint, params, *args, **kwargs)
    except BaseException:
        stat['stop'] = 'request_failed_or_cancelled'
        raise
    stat['pages'] += 1
    ids = set()
    bottom = None
    instructions = False
    def walk(value):
        nonlocal bottom, instructions
        if isinstance(value, dict):
            if isinstance(value.get('instructions'), list): instructions = True
            entry = value.get('entryId', '')
            if isinstance(entry, str) and entry.startswith('tweet-'): ids.add(entry)
            if value.get('cursorType') == 'Bottom': bottom = value.get('value')
            for child in value.values(): walk(child)
        elif isinstance(value, list):
            for child in value: walk(child)
    walk(data)
    stat['lastPageEntries'] = len(ids)
    stat['entries'] += len(ids)
    try: previous = json.loads(params.get('variables', '{}')).get('cursor')
    except (TypeError, ValueError): previous = None
    if not instructions: stop = 'unrecognized_response'
    elif not bottom: stop = 'no_next_cursor'
    elif bottom == previous: stop = 'repeated_cursor'
    elif not ids: stop = 'empty_page_with_cursor'
    else: stop = 'stopped_with_next_cursor'
    stat['stop'] = stop
    if page_mode:
        next_cursor = bottom if bottom and bottom != previous else None
        page_state[kind] = next_cursor
        terminators[kind] = without_instructions(data)
    return data
twitter.TwitterAPI._call = call

def report():
    for stat in observations.values():
        sys.stderr.write('CLIPBOX_SCAN ' + json.dumps(stat) + '\n')
    if page_mode:
        for kind in ('Likes', 'Bookmarks'):
            if kind in observations:
                sys.stderr.write('CLIPBOX_PAGESTATE ' + json.dumps(dict(
                    collection=kind, nextCursor=page_state.get(kind)), separators=(',', ':')) + '\n')
atexit.register(report)
from gallery_dl import main
main()
"""#

    static let identityScript = #"""
import sys, json, os, re, urllib.parse
from gallery_dl import cookies, extractor
from gallery_dl.extractor import twitter

store = sys.argv[1]
spec = json.loads(sys.argv[2])
if store:
    if os.path.basename(store) != 'Cookies.binarycookies':
        raise SystemExit('Unsupported Safari cookie file')
    cookies._safari_cookies_database = lambda: open(store, 'rb')

obj = extractor.find('https://x.com/i/bookmarks')
obj.initialize()
loaded = cookies.load_cookies(spec)
for cookie in loaded:
    obj.cookies.set_cookie(cookie)

auth_present = obj.cookies.get('auth_token', domain=obj.cookies_domain) is not None
twid = obj.cookies.get('twid', domain=obj.cookies_domain)
claimed = None
if isinstance(twid, str):
    decoded = urllib.parse.unquote(twid).strip('"')
    match = re.search(r'(?:^|&)u=(\d+)(?:&|$)', decoded)
    if match:
        claimed = match.group(1)

result = dict(connected=bool(auth_present), cookieUserID=claimed,
              serverUserID=None, handle=None, serverVerified=False)
if auth_present and claimed:
    obj.api = twitter.TwitterAPI(obj)
    user = obj.api.user_by_rest_id(claimed)
    if isinstance(user, dict) and user.get('rest_id'):
        core = user.get('core') or user.get('legacy') or {}
        result['serverUserID'] = str(user.get('rest_id'))
        result['handle'] = core.get('screen_name')
        result['serverVerified'] = result['serverUserID'] == claimed

sys.stdout.write(json.dumps(result, separators=(',', ':')))
"""#
}
