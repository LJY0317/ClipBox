import Foundation

public enum HistoryExchangeFormat: String, CaseIterable, Codable, Sendable {
    case jsonl
    case csv
    case xlsx

    public static func infer(from url: URL) -> HistoryExchangeFormat? {
        HistoryExchangeFormat(rawValue: url.pathExtension.lowercased())
    }
}

public struct HistoryExportResult: Codable, Equatable, Sendable {
    public let path: String
    public let format: HistoryExchangeFormat
    public let recordCount: Int

    public init(path: String, format: HistoryExchangeFormat, recordCount: Int) {
        self.path = path
        self.format = format
        self.recordCount = recordCount
    }
}

public struct HistoryImportResult: Codable, Equatable, Sendable {
    public let format: HistoryExchangeFormat
    public let recordsProcessed: Int
    public let recordsAdded: Int
    public let finalRecordCount: Int

    public init(
        format: HistoryExchangeFormat,
        recordsProcessed: Int,
        recordsAdded: Int,
        finalRecordCount: Int
    ) {
        self.format = format
        self.recordsProcessed = recordsProcessed
        self.recordsAdded = recordsAdded
        self.finalRecordCount = finalRecordCount
    }
}

public enum HistoryExchangeError: Error, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case malformedCSV(String)
    case malformedRecord(String)
    case archiveToolUnavailable
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let value):
            "Unsupported history exchange format: \(value)."
        case .malformedCSV(let message):
            "Could not parse ClipBox CSV history: \(message)"
        case .malformedRecord(let message):
            "Could not import a ClipBox history record: \(message)"
        case .archiveToolUnavailable:
            "The macOS `ditto` archive tool is unavailable, so XLSX export cannot be created."
        case .exportFailed(let message):
            "Could not export ClipBox history: \(message)"
        }
    }
}

public actor HistoryExchangeService {
    private let archive: ArchiveStore
    private let dittoURL: URL?

    private static let columns: [(key: String, title: String)] = [
        ("site", "site"),
        ("media_id", "media_id"),
        ("source_id", "source_id"),
        ("collection", "collection"),
        ("source_url", "source_url"),
        ("creator", "creator"),
        ("title", "title"),
        ("published_at", "published_at"),
        ("first_seen_at", "first_seen_at"),
        ("downloaded_at", "downloaded_at"),
        ("width", "width"),
        ("height", "height"),
        ("fps", "fps"),
        ("video_codec", "video_codec"),
        ("audio_codec", "audio_codec"),
        ("format_id", "format_id"),
        ("output_path", "output_path"),
        ("status", "status"),
        ("last_error", "last_error"),
    ]

    public init(
        archive: ArchiveStore? = nil,
        dittoURL: URL? = URL(fileURLWithPath: "/usr/bin/ditto")
    ) throws {
        self.archive = try archive ?? ArchiveStore()
        if let dittoURL, FileManager.default.isExecutableFile(atPath: dittoURL.path) {
            self.dittoURL = dittoURL
        } else {
            self.dittoURL = nil
        }
    }

    public func export(
        to requestedURL: URL,
        format explicitFormat: HistoryExchangeFormat? = nil
    ) async throws -> HistoryExportResult {
        let format = explicitFormat ?? HistoryExchangeFormat.infer(from: requestedURL)
        guard let format else {
            throw HistoryExchangeError.unsupportedFormat(requestedURL.pathExtension)
        }
        let destination = Self.destinationURL(requestedURL, format: format)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let records = try await archive.allRecords()
        switch format {
        case .jsonl:
            try writeJSONL(records, to: destination)
        case .csv:
            try writeCSV(records, to: destination)
        case .xlsx:
            try writeXLSX(records, to: destination)
        }

        return HistoryExportResult(
            path: destination.path,
            format: format,
            recordCount: records.count
        )
    }

    public func importHistory(
        from sourceURL: URL,
        format explicitFormat: HistoryExchangeFormat? = nil
    ) async throws -> HistoryImportResult {
        let format = explicitFormat ?? HistoryExchangeFormat.infer(from: sourceURL)
        guard let format else {
            throw HistoryExchangeError.unsupportedFormat(sourceURL.pathExtension)
        }

        let records: [ArchiveRecord]
        switch format {
        case .jsonl:
            records = try readJSONL(from: sourceURL)
        case .csv:
            records = try readCSV(from: sourceURL)
        case .xlsx:
            throw HistoryExchangeError.unsupportedFormat(
                "XLSX import is not enabled yet; use .clipboxbackup, JSONL, or CSV for migration"
            )
        }

        let before = try await archive.count()
        let processed = try await archive.importRecords(records)
        let after = try await archive.count()
        return HistoryImportResult(
            format: format,
            recordsProcessed: processed,
            recordsAdded: max(0, after - before),
            finalRecordCount: after
        )
    }

    private func writeJSONL(_ records: [ArchiveRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private func readJSONL(from url: URL) throws -> [ArchiveRecord] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var records: [ArchiveRecord] = []
        for (index, line) in raw.split(whereSeparator: \.isNewline).enumerated() {
            do {
                records.append(try decoder.decode(ArchiveRecord.self, from: Data(line.utf8)))
            } catch {
                throw HistoryExchangeError.malformedRecord(
                    "JSONL line \(index + 1): \(error.localizedDescription)"
                )
            }
        }
        return records
    }

    private func writeCSV(_ records: [ArchiveRecord], to url: URL) throws {
        var output = "\u{FEFF}"
        output += Self.columns.map { Self.csvQuote($0.title) }.joined(separator: ",") + "\r\n"
        for record in records {
            let values = Self.rowValues(record)
            output += Self.columns.map { column in
                Self.csvQuote(Self.csvSpreadsheetSafe(values[column.key] ?? ""))
            }.joined(separator: ",") + "\r\n"
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readCSV(from url: URL) throws -> [ArchiveRecord] {
        var raw = try String(contentsOf: url, encoding: .utf8)
        if raw.first == "\u{FEFF}" {
            raw.removeFirst()
        }
        let rows = try Self.parseCSV(raw)
        guard let header = rows.first else { return [] }
        let normalizedHeader = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var records: [ArchiveRecord] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.isEmpty }) { continue }
            var values: [String: String] = [:]
            for (index, key) in normalizedHeader.enumerated() where index < row.count {
                values[key] = Self.csvSpreadsheetUnsafe(row[index])
            }
            records.append(try Self.record(from: values, rowNumber: offset + 2))
        }
        return records
    }

    private func writeXLSX(_ records: [ArchiveRecord], to destination: URL) throws {
        guard let dittoURL else {
            throw HistoryExchangeError.archiveToolUnavailable
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipBoxXLSX-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let rels = staging.appendingPathComponent("_rels", isDirectory: true)
        let xl = staging.appendingPathComponent("xl", isDirectory: true)
        let xlRels = xl.appendingPathComponent("_rels", isDirectory: true)
        let worksheets = xl.appendingPathComponent("worksheets", isDirectory: true)
        for directory in [staging, rels, xl, xlRels, worksheets] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try Self.xlsxContentTypes.write(
            to: staging.appendingPathComponent("[Content_Types].xml"),
            atomically: true,
            encoding: .utf8
        )
        try Self.xlsxRootRelationships.write(
            to: rels.appendingPathComponent(".rels"),
            atomically: true,
            encoding: .utf8
        )
        try Self.xlsxWorkbook.write(
            to: xl.appendingPathComponent("workbook.xml"),
            atomically: true,
            encoding: .utf8
        )
        try Self.xlsxWorkbookRelationships.write(
            to: xlRels.appendingPathComponent("workbook.xml.rels"),
            atomically: true,
            encoding: .utf8
        )
        try Self.xlsxSheet(records).write(
            to: worksheets.appendingPathComponent("sheet1.xml"),
            atomically: true,
            encoding: .utf8
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let result = try ProcessRunner.run(
            executable: dittoURL,
            arguments: ["-c", "-k", "--norsrc", staging.path, destination.path]
        )
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw HistoryExchangeError.exportFailed(message)
        }
    }

    private static func rowValues(_ record: ArchiveRecord) -> [String: String] {
        [
            "site": record.site,
            "media_id": record.mediaID,
            "source_id": record.sourceID ?? "",
            "collection": record.collection ?? "",
            "source_url": record.sourceURL ?? "",
            "creator": record.creator ?? "",
            "title": record.title ?? "",
            "published_at": record.publishedAt ?? "",
            "first_seen_at": record.firstSeenAt,
            "downloaded_at": record.downloadedAt ?? "",
            "width": record.width.map { String($0) } ?? "",
            "height": record.height.map { String($0) } ?? "",
            "fps": record.fps.map { String($0) } ?? "",
            "video_codec": record.videoCodec ?? "",
            "audio_codec": record.audioCodec ?? "",
            "format_id": record.formatID ?? "",
            "output_path": record.outputPath ?? "",
            "status": record.status.rawValue,
            "last_error": record.lastError ?? "",
        ]
    }

    private static func record(from values: [String: String], rowNumber: Int) throws -> ArchiveRecord {
        let site = values["site"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mediaID = values["media_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !site.isEmpty, !mediaID.isEmpty else {
            throw HistoryExchangeError.malformedRecord(
                "CSV row \(rowNumber) must contain non-empty site and media_id values"
            )
        }
        let rawStatus = values["status"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let status = ArchiveStatus(rawValue: rawStatus) else {
            throw HistoryExchangeError.malformedRecord(
                "CSV row \(rowNumber) has unsupported status `\(rawStatus)`"
            )
        }
        let firstSeen = Self.nilIfEmpty(values["first_seen_at"])
            ?? ISO8601DateFormatter().string(from: Date())

        return ArchiveRecord(
            site: site,
            mediaID: mediaID,
            sourceID: Self.nilIfEmpty(values["source_id"]),
            collection: Self.nilIfEmpty(values["collection"]),
            sourceURL: Self.nilIfEmpty(values["source_url"]),
            creator: Self.nilIfEmpty(values["creator"]),
            title: Self.nilIfEmpty(values["title"]),
            publishedAt: Self.nilIfEmpty(values["published_at"]),
            firstSeenAt: firstSeen,
            downloadedAt: Self.nilIfEmpty(values["downloaded_at"]),
            width: Self.nilIfEmpty(values["width"]).flatMap(Int.init),
            height: Self.nilIfEmpty(values["height"]).flatMap(Int.init),
            fps: Self.nilIfEmpty(values["fps"]).flatMap(Double.init),
            videoCodec: Self.nilIfEmpty(values["video_codec"]),
            audioCodec: Self.nilIfEmpty(values["audio_codec"]),
            formatID: Self.nilIfEmpty(values["format_id"]),
            outputPath: Self.nilIfEmpty(values["output_path"]),
            status: status,
            lastError: Self.nilIfEmpty(values["last_error"])
        )
    }

    private static func csvQuote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func csvSpreadsheetSafe(_ value: String) -> String {
        guard let first = value.first, "=+-@\t\r".contains(first) else { return value }
        return "'" + value
    }

    private static func csvSpreadsheetUnsafe(_ value: String) -> String {
        guard value.first == "'", value.count > 1 else { return value }
        let second = value[value.index(after: value.startIndex)]
        return "=+-@\t\r".contains(second) ? String(value.dropFirst()) : value
    }

    private static func parseCSV(_ input: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if inQuotes {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else {
                if character.isNewline {
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                    index = input.index(after: index)
                    continue
                }

                switch character {
                case "\"":
                    if !field.isEmpty {
                        throw HistoryExchangeError.malformedCSV("unexpected quote inside unquoted field")
                    }
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                default:
                    field.append(character)
                }
            }
            index = input.index(after: index)
        }

        guard !inQuotes else {
            throw HistoryExchangeError.malformedCSV("unterminated quoted field")
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func destinationURL(_ requestedURL: URL, format: HistoryExchangeFormat) -> URL {
        requestedURL.pathExtension.lowercased() == format.rawValue
            ? requestedURL
            : requestedURL.appendingPathExtension(format.rawValue)
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func xlsxSheet(_ records: [ArchiveRecord]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        xml += xlsxRow(
            rowNumber: 1,
            values: columns.map(\.title)
        )
        for (offset, record) in records.enumerated() {
            let values = rowValues(record)
            xml += xlsxRow(
                rowNumber: offset + 2,
                values: columns.map { values[$0.key] ?? "" }
            )
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func xlsxRow(rowNumber: Int, values: [String]) -> String {
        var row = "<row r=\"\(rowNumber)\">"
        for (index, value) in values.enumerated() {
            let reference = "\(xlsxColumnName(index + 1))\(rowNumber)"
            let escaped = xmlEscape(xmlSanitize(value))
            row += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escaped)</t></is></c>"
        }
        row += "</row>"
        return row
    }

    private static func xlsxColumnName(_ index: Int) -> String {
        var value = index
        var result = ""
        while value > 0 {
            value -= 1
            let scalar = UnicodeScalar(65 + (value % 26))!
            result.insert(Character(scalar), at: result.startIndex)
            value /= 26
        }
        return result
    }

    private static func xmlSanitize(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar.value == 0x09
                || scalar.value == 0x0A
                || scalar.value == 0x0D
                || scalar.value >= 0x20
        })
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let xlsxContentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    private static let xlsxRootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let xlsxWorkbook = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets><sheet name="History" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    private static let xlsxWorkbookRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
    """
}
