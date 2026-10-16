import CLibXML2
import Foundation

/// An HTML page parsed into a tree that XPath expressions can be run over.
///
/// This is the whole of what a source rule's selectors need. libxml2's HTML
/// parser is used in recovery mode because the pages these rules are written
/// against are not well-formed and never will be: unclosed tags, stray
/// attributes, markup assembled by a template nobody validates.
///
/// Not `Sendable`: the document owns a libxml2 tree, and a node is a pointer
/// into it. Parse and select on one task.
public final class HTMLSelector {
    private let document: htmlDocPtr

    /// libxml2 wants its parser initialized once before any thread uses it.
    /// A global `let` is initialized lazily and exactly once, which is the
    /// guarantee needed here.
    private static let libraryIsReady: Void = { xmlInitParser() }()

    /// Parses bytes as HTML, deciding the text encoding first.
    ///
    /// The encoding is settled in Swift rather than handed to libxml2,
    /// because these sites are the same mix the fansub world is: a Chinese
    /// index serving GBK with no declaration at all is ordinary. Decoding to
    /// a Swift string and parsing that as UTF-8 makes every rule see the
    /// same thing whatever the page arrived as.
    public convenience init?(data: Data) {
        guard let text = HTMLSelector.decode(data) else { return nil }
        self.init(html: text)
    }

    public init?(html: String) {
        _ = HTMLSelector.libraryIsReady
        var html = html
        guard let document = html.withUTF8({ buffer -> htmlDocPtr? in
            guard let base = buffer.baseAddress else { return nil }
            return htmlReadMemory(
                base, Int32(buffer.count), nil, "UTF-8",
                Int32(
                    HTML_PARSE_RECOVER.rawValue
                        | HTML_PARSE_NOERROR.rawValue
                        | HTML_PARSE_NOWARNING.rawValue
                        | HTML_PARSE_NONET.rawValue
                )
            )
        }) else { return nil }
        self.document = document
    }

    deinit { xmlFreeDoc(document) }

    /// The nodes an expression selects, anchored at the document.
    public func nodes(forXPath expression: String) -> [HTMLElement] {
        evaluate(expression, within: nil)
    }

    /// The first node an expression selects, or nil.
    public func node(forXPath expression: String) -> HTMLElement? {
        nodes(forXPath: expression).first
    }

    fileprivate func evaluate(_ expression: String, within node: xmlNodePtr?) -> [HTMLElement] {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return [] }
        guard let context = xmlXPathNewContext(document) else { return [] }
        defer { xmlXPathFreeContext(context) }
        if let node { context.pointee.node = node }
        guard let result = xmlXPathEvalExpression(HTMLSelector.scoped(expression, within: node), context) else {
            return []
        }
        defer { xmlXPathFreeObject(result) }
        guard let set = result.pointee.nodesetval, set.pointee.nodeNr > 0, let table = set.pointee.nodeTab else {
            return []
        }
        return (0..<Int(set.pointee.nodeNr)).compactMap { index in
            table[index].map { HTMLElement(node: $0, document: self) }
        }
    }

    /// Anchors a rule's expression to the node it is being run inside.
    ///
    /// A rule's inner selectors are written with a leading `//` — Kazumi's
    /// `searchName` is `//div[3]/div[1]/div[1]`, its `chapterResult` is
    /// `//li/a` — and are meant to search *within* the row or the line
    /// currently being read. In XPath 1.0 a leading `//` means
    /// `/descendant-or-self::node()/`, which is anchored at the document
    /// however the context node is set, so taken literally every row would
    /// be handed the whole page's matches and the first row's answer would
    /// be copied onto all of them. Dart's `xpath_selector`, which Kazumi
    /// evaluates these with, scopes them to the node implicitly.
    ///
    /// Measured on a real search page: `//div[3]/div[2]/a[1]` inside a result
    /// row matched 2 nodes unscoped against 1 scoped, and `//li/a` inside one
    /// playback line matched 62 unscoped against 24 scoped — two lines of a
    /// show collapsed into one wrong list.
    static func scoped(_ expression: String, within node: xmlNodePtr?) -> String {
        guard node != nil, expression.hasPrefix("//") else { return expression }
        return "." + expression
    }

    /// Decodes page bytes, preferring what the page says about itself.
    ///
    /// A `<meta charset>` is sniffed out of the head before anything is
    /// decoded, because the general decoder scores Chinese code pages against
    /// each other and a page that declares Big5 should not be argued with.
    static func decode(_ data: Data) -> String? {
        if let declared = declaredEncoding(data), let text = String(data: data, encoding: declared) {
            return text
        }
        return SubtitleTextDecoder.decode(data)?.text
    }

    /// The charset a page declares, read from the first 4 KB — a `<meta>`
    /// that appears after that much markup is not what the browser used
    /// either.
    static func declaredEncoding(_ data: Data) -> String.Encoding? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        guard let range = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-]+)"#, options: .regularExpression) else {
            return nil
        }
        let name = head[range]
            .split(separator: "=", maxSplits: 1).last?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) ?? ""
        switch name {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        case "big5", "big5-hkscs":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)
                )
            )
        case "shift_jis", "shift-jis", "sjis":
            return .shiftJIS
        case "euc-jp": return .japaneseEUC
        case "iso-8859-1", "latin1": return .isoLatin1
        default: return nil
        }
    }
}

/// One node of a parsed page: what a rule reads a name, a link or a nested
/// list out of.
public struct HTMLElement {
    fileprivate let node: xmlNodePtr
    /// Keeps the tree this node points into alive for as long as the node is.
    private let document: HTMLSelector

    fileprivate init(node: xmlNodePtr, document: HTMLSelector) {
        self.node = node
        self.document = document
    }

    /// The node's text, descendants included, with surrounding whitespace
    /// removed.
    public var text: String {
        guard let content = xmlNodeGetContent(node) else { return "" }
        defer { ag_xml_free(content) }
        return String(cString: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The node's text with *all* whitespace removed, which is how an
    /// episode label is read: `第 01 集` spread over three lines in the
    /// markup is one label.
    public var compactText: String {
        text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    public var name: String {
        guard let name = node.pointee.name else { return "" }
        return String(cString: name)
    }

    public func attribute(_ name: String) -> String? {
        guard let value = xmlGetProp(node, name) else { return nil }
        defer { ag_xml_free(value) }
        return String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The nodes an expression selects inside this one. A leading `//` is
    /// anchored here rather than at the document — see `HTMLSelector.scoped`.
    public func nodes(forXPath expression: String) -> [HTMLElement] {
        document.evaluate(expression, within: node)
    }

    public func node(forXPath expression: String) -> HTMLElement? {
        nodes(forXPath: expression).first
    }

    /// This node's own markup. Kept for the rule editor's preview, which
    /// shows which fragment of the page a selector matched.
    public var outerHTML: String {
        guard let buffer = xmlBufferCreate() else { return "" }
        defer { xmlBufferFree(buffer) }
        guard htmlNodeDump(buffer, node.pointee.doc, node) >= 0,
              let content = xmlBufferContent(buffer)
        else { return "" }
        return String(cString: content)
    }
}
