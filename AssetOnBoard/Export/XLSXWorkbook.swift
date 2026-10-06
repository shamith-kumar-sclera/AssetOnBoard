//
//  XLSXWorkbook.swift
//  AssetOnBoard
//
//  Builds a SpreadsheetML (.xlsx) workbook.
//
//  Values are written as inline strings rather than through a shared-strings
//  table: the data here is mostly unique (banners, hostnames, TXT records), so
//  deduplication would buy nothing and the file stays far simpler to generate.
//

import Foundation

nonisolated enum XLSXCell: Sendable {
    case empty
    case text(String)
    case number(Double)
    case integer(Int)
    case date(Date)
    case boolean(Bool)
    /// Rendered with the header style; used for titles inside a side block.
    case heading(String)

    static func text(_ value: String?) -> XLSXCell {
        guard let value, !value.isEmpty else { return .empty }
        return .text(value)
    }
}

nonisolated struct XLSXColumn: Sendable {
    let title: String
    let width: Double

    init(_ title: String, width: Double = 18) {
        self.title = title
        self.width = width
    }
}

nonisolated struct XLSXSheet: Sendable {
    /// Excel rejects : \ / ? * [ ] in sheet names and caps them at 31 characters.
    let name: String
    let columns: [XLSXColumn]
    var rows: [[XLSXCell]]

    /// An independent block of cells placed to the right of the main table.
    ///
    /// Kept outside the autofilter range deliberately: anything written *below*
    /// a filterable table gets scrambled the first time someone sorts it.
    let sideColumns: [XLSXColumn]
    let sideRows: [[XLSXCell]]
    /// Blank columns separating the table from the side block.
    let sideGap: Int

    init(name: String,
         columns: [XLSXColumn],
         rows: [[XLSXCell]] = [],
         sideColumns: [XLSXColumn] = [],
         sideRows: [[XLSXCell]] = [],
         sideGap: Int = 2) {
        self.sideColumns = sideColumns
        self.sideRows = sideRows
        self.sideGap = sideGap
        self.name = String(name.replacingOccurrences(of: "[:\\\\/?*\\[\\]]",
                                                     with: "-",
                                                     options: .regularExpression).prefix(31))
        self.columns = columns
        self.rows = rows
    }

    /// First column index occupied by the side block.
    var sideStartColumn: Int { columns.count + sideGap }
}

nonisolated struct XLSXWorkbook {

    var sheets: [XLSXSheet]

    /// Style indices defined in `styles.xml` below.
    private enum Style: Int {
        case normal = 0
        case header = 1
        case dateTime = 2
        case wrapped = 3
    }

    func data() -> Data {
        var archive = ZIPArchive()
        archive.addFile(path: "[Content_Types].xml", string: contentTypes())
        archive.addFile(path: "_rels/.rels", string: rootRelationships())
        archive.addFile(path: "xl/workbook.xml", string: workbookXML())
        archive.addFile(path: "xl/_rels/workbook.xml.rels", string: workbookRelationships())
        archive.addFile(path: "xl/styles.xml", string: stylesXML())
        for (index, sheet) in sheets.enumerated() {
            archive.addFile(path: "xl/worksheets/sheet\(index + 1).xml", string: sheetXML(sheet))
        }
        return archive.data()
    }

    // MARK: - Parts

    private func contentTypes() -> String {
        let overrides = sheets.indices.map {
            "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(overrides)</Types>
        """
    }

    private func rootRelationships() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
    }

    private func workbookXML() -> String {
        let entries = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(Self.escape(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(entries)</sheets></workbook>
        """
    }

    private func workbookRelationships() -> String {
        let entries = sheets.indices.map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(entries)</Relationships>
        """
    }

    private func stylesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="2">\
        <font><sz val="11"/><name val="Calibri"/></font>\
        <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>\
        </fonts>\
        <fills count="3">\
        <fill><patternFill patternType="none"/></fill>\
        <fill><patternFill patternType="gray125"/></fill>\
        <fill><patternFill patternType="solid"><fgColor rgb="FF1F6FEB"/><bgColor indexed="64"/></patternFill></fill>\
        </fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="4">\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"><alignment vertical="center"/></xf>\
        <xf numFmtId="22" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>\
        </cellXfs></styleSheet>
        """
    }

    private func sheetXML(_ sheet: XLSXSheet) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetViews><sheetView workbookViewId="0">\
        <pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>\
        </sheetView></sheetViews>
        """

        var columnXML = sheet.columns.enumerated().map { index, column in
            "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(column.width)\" customWidth=\"1\"/>"
        }
        columnXML += sheet.sideColumns.enumerated().map { index, column in
            let position = sheet.sideStartColumn + index + 1
            return "<col min=\"\(position)\" max=\"\(position)\" width=\"\(column.width)\" customWidth=\"1\"/>"
        }
        if !columnXML.isEmpty { xml += "<cols>\(columnXML.joined())</cols>" }

        xml += "<sheetData>"

        // Row 1 carries both sets of headers.
        var headerCells = sheet.columns.enumerated().map { index, column in
            cellXML(.text(column.title), row: 1, column: index, style: .header)
        }.joined()
        headerCells += sheet.sideColumns.enumerated().map { index, column in
            cellXML(.text(column.title), row: 1, column: sheet.sideStartColumn + index, style: .header)
        }.joined()
        xml += "<row r=\"1\">\(headerCells)</row>"

        for offset in 0..<max(sheet.rows.count, sheet.sideRows.count) {
            let number = offset + 2
            var cells = ""
            if offset < sheet.rows.count {
                cells += sheet.rows[offset].enumerated().map { index, value in
                    cellXML(value, row: number, column: index, style: style(for: value))
                }.joined()
            }
            if offset < sheet.sideRows.count {
                cells += sheet.sideRows[offset].enumerated().map { index, value in
                    cellXML(value, row: number, column: sheet.sideStartColumn + index, style: style(for: value))
                }.joined()
            }
            guard !cells.isEmpty else { continue }
            xml += "<row r=\"\(number)\">\(cells)</row>"
        }
        xml += "</sheetData>"

        // Filter spans only the device table, never the side block.
        if !sheet.columns.isEmpty {
            let lastColumn = Self.columnName(sheet.columns.count - 1)
            xml += "<autoFilter ref=\"A1:\(lastColumn)\(max(sheet.rows.count + 1, 1))\"/>"
        }
        xml += "</worksheet>"
        return xml
    }

    private func style(for cell: XLSXCell) -> Style {
        switch cell {
        case .date: .dateTime
        case .heading: .header
        default: .normal
        }
    }

    private func cellXML(_ cell: XLSXCell, row: Int, column: Int, style: Style) -> String {
        let reference = "\(Self.columnName(column))\(row)"
        let styleAttribute = style == .normal ? "" : " s=\"\(style.rawValue)\""

        switch cell {
        case .empty:
            return styleAttribute.isEmpty ? "" : "<c r=\"\(reference)\"\(styleAttribute)/>"
        case .text(let value):
            return "<c r=\"\(reference)\"\(styleAttribute) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(Self.escape(value))</t></is></c>"
        case .number(let value):
            guard value.isFinite else { return "" }
            return "<c r=\"\(reference)\"\(styleAttribute)><v>\(value)</v></c>"
        case .integer(let value):
            return "<c r=\"\(reference)\"\(styleAttribute)><v>\(value)</v></c>"
        case .date(let value):
            return "<c r=\"\(reference)\" s=\"\(Style.dateTime.rawValue)\"><v>\(Self.excelSerial(value))</v></c>"
        case .boolean(let value):
            return "<c r=\"\(reference)\"\(styleAttribute) t=\"b\"><v>\(value ? 1 : 0)</v></c>"
        case .heading(let value):
            return "<c r=\"\(reference)\" s=\"\(Style.header.rawValue)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(Self.escape(value))</t></is></c>"
        }
    }

    // MARK: - Helpers

    /// 0 -> A, 25 -> Z, 26 -> AA.
    static func columnName(_ index: Int) -> String {
        var value = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + value % 26))) + name
            value = value / 26 - 1
        } while value >= 0
        return name
    }

    /// Days since 1899-12-30, the epoch Excel counts from.
    private static func excelSerial(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 25_569
    }

    /// Escapes XML markup and drops the control characters XML 1.0 forbids.
    ///
    /// Service banners are raw bytes off the wire and routinely contain both.
    static func escape(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count + 16)
        for scalar in value.prefix(32_767).unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            case "\t", "\n", "\r": output.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                    output += " "
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }
}
