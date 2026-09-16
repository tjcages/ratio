import AppKit
import CoreGraphics
import Sparkle
import Security
import CryptoKit

// Pure accounting: unknown, paused, and idle time never enter the ratio.
struct AppUsage: Codable {
    var name: String
    var seconds: Double = 0
    var unclassified: Double? = 0
    var createSeconds: Double?
    var consumeSeconds: Double?
    var lastUsed: Double?
    var browserID: String?
    var browserName: String?
}

// Titles and URLs stay in memory. Persist only the host and an opaque page key.
struct BrowserPage {
    let id: String
    let browserID: String
    let browserName: String
    let host: String
    let title: String

    init?(url: String, title: String, browserID: String, browserName: String) {
        guard var parts = URLComponents(string: url),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host
        parts.user = nil; parts.password = nil; parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        guard let identity = parts.string else { return nil }
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        self.id = "page:" + browserID + ":" + digest
        self.browserID = browserID; self.browserName = browserName
        self.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.host : title
    }

    var usage: AppUsage { AppUsage(name: host, browserID: browserID, browserName: browserName) }
}

struct BrowserSnapshot {
    var pages: [BrowserPage]
    var active: BrowserPage?
    var error: String?

    static func read(id: String, name: String) -> BrowserSnapshot {
        let activeTab = id == "com.apple.Safari" ? "current tab" : "active tab"
        let titleProperty = id == "com.apple.Safari" ? "name" : "title"
        let source = """
        tell application id "\(id)"
            with timeout of 5 seconds
                set pageRows to {}
                set activeURL to ""
                if (count of windows) > 0 then
                    try
                        set activeURL to URL of \(activeTab) of front window
                    end try
                    repeat with browserWindow in windows
                        repeat with browserTab in tabs of browserWindow
                            try
                                set end of pageRows to {URL of browserTab, \(titleProperty) of browserTab}
                            end try
                        end repeat
                    end repeat
                end if
                return {activeURL, pageRows}
            end timeout
        end tell
        """
        var failure: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&failure)
        if let failure = failure {
            let denied = (failure[NSAppleScript.errorNumber] as? Int) == -1743
            return BrowserSnapshot(pages: [], error: denied
                ? "Allow Ratio in System Settings → Privacy & Security → Automation."
                : "Tabs unavailable. Browser time still counts; expand to retry.")
        }
        guard let result = result, result.numberOfItems == 2,
              let rows = result.atIndex(2) else {
            return BrowserSnapshot(pages: [], error: "Tabs unavailable. Expand to retry.")
        }
        var pages: [BrowserPage] = []
        var seen = Set<String>()
        if rows.numberOfItems > 0 {
            for index in 1...rows.numberOfItems {
                guard let row = rows.atIndex(index), let url = row.atIndex(1)?.stringValue,
                      let page = BrowserPage(url: url, title: row.atIndex(2)?.stringValue ?? "", browserID: id, browserName: name),
                      seen.insert(page.id).inserted else { continue }
                pages.append(page)
            }
        }
        let active = BrowserPage(url: result.atIndex(1)?.stringValue ?? "", title: "", browserID: id, browserName: name)
        if let active = active, seen.insert(active.id).inserted { pages.append(active) }
        return BrowserSnapshot(pages: pages, active: active)
    }
}

struct ActivityRow {
    let id: String
    let name: String
    let detail: String
    let seconds: Double
    var browserID: String? = nil
    var expandable = false
    var active = false
    var message = false
}

struct Ledger: Codable {
    var day: String
    var consume: Double = 0
    var create: Double = 0
    var apps: [String: AppUsage]? = [:] // Optional preserves totals saved by v0.1.
    mutating func record(_ seconds: Double, mode: String?, appID: String = "", appName: String = "") {
        guard seconds > 0, seconds <= 3 else { return }
        if !appID.isEmpty {
            var usage = apps ?? [:]
            var entry = usage[appID] ?? AppUsage(name: appName)
            if entry.createSeconds == nil || entry.consumeSeconds == nil {
                let classified = max(0, entry.seconds - (entry.unclassified ?? 0))
                entry.createSeconds = mode == "create" ? classified : 0
                entry.consumeSeconds = mode == "consume" ? classified : 0
            }
            entry.name = appName; entry.seconds += seconds; entry.lastUsed = Date().timeIntervalSince1970
            if mode == "create" { entry.createSeconds = (entry.createSeconds ?? 0) + seconds }
            if mode == "consume" { entry.consumeSeconds = (entry.consumeSeconds ?? 0) + seconds }
            if mode == nil { entry.unclassified = (entry.unclassified ?? 0) + seconds }
            usage[appID] = entry; apps = usage
        }
        if mode == "create" { create += seconds }
        if mode == "consume" { consume += seconds }
    }
    mutating func classifyPending(_ id: String, mode: String?, previousMode: String? = nil) {
        guard mode == nil || mode == "create" || mode == "consume" || mode == "neutral", var usage = apps?[id] else { return }
        let classified = max(0, usage.seconds - (usage.unclassified ?? 0))
        let oldCreate = usage.createSeconds ?? (previousMode == "create" ? classified : 0)
        let oldConsume = usage.consumeSeconds ?? (previousMode == "consume" ? classified : 0)
        create = max(0, create - oldCreate)
        consume = max(0, consume - oldConsume)
        usage.createSeconds = mode == "create" ? usage.seconds : 0
        usage.consumeSeconds = mode == "consume" ? usage.seconds : 0
        create += usage.createSeconds ?? 0
        consume += usage.consumeSeconds ?? 0
        usage.unclassified = mode == nil ? usage.seconds : 0; apps?[id] = usage
    }


}

struct DaySummary: Codable {
    var day: String
    var create: Double
    var consume: Double
}
struct ResetSnapshot {
    var ledger: Ledger
    var rules: [String: String]
    var activeSeconds: Double
    var paused: Bool
    var prompted: Set<String>
    var chromeSessionSites: Set<String>
    var mode: String?
}
func dayKey(_ date: Date = Date()) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
}

// One type scale throughout the interface; only the ratio is enlarged.
let interfaceFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
var lightMode = UserDefaults.standard.bool(forKey: "lightMode")
var panelBackground: NSColor { NSColor(white: lightMode ? 0.97 : 0.06, alpha: 1) }
var panelText: NSColor { lightMode ? .black : .white }
var selectionBackground: NSColor { NSColor(white: lightMode ? 0.91 : 0.075, alpha: 1) }
let createColor = NSColor(srgbRed: 40/255, green: 205/255, blue: 65/255, alpha: 1)
let consumeColor = NSColor(srgbRed: 1, green: 59/255, blue: 48/255, alpha: 1)
let unclassifiedColor = NSColor(srgbRed: 1, green: 159/255, blue: 10/255, alpha: 1)
var gridColor: NSColor { NSColor(white: lightMode ? 0.8 : 0.14, alpha: 1) }
func hairline(_ rect: NSRect) { gridColor.setFill(); NSBezierPath(rect: rect).fill() }

// Lucide Moon geometry, matching the web icon (ISC license).
func drawWebMoon(in bounds: NSRect, color: NSColor, flipped: Bool) {
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(translationByX: bounds.midX - 7, byY: bounds.midY + (flipped ? -7 : 7))
    var scaled = transform
    scaled.scale(x: 14 / 24, y: (flipped ? 14.0 : -14.0) / 24)
    (scaled as NSAffineTransform).concat()
    let p = NSBezierPath()
    p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: 20.985000000, y: 12.486000000))
    p.curve(to: NSPoint(x: 11.836619803, y: 20.999415324), controlPoint1: NSPoint(x: 20.723859872, y: 17.323495733), controlPoint2: NSPoint(x: 16.680379204, y: 21.086329102))
    p.curve(to: NSPoint(x: 2.999550507, y: 12.163278897), controlPoint1: NSPoint(x: 6.992860402, y: 20.912501545), controlPoint2: NSPoint(x: 3.086975635, y: 17.007029095))
    p.curve(to: NSPoint(x: 11.512000000, y: 3.014000000), controlPoint1: NSPoint(x: 2.912125379, y: 7.319528698), controlPoint2: NSPoint(x: 6.674531862, y: 3.275650815))
    p.curve(to: NSPoint(x: 11.914000000, y: 3.817000000), controlPoint1: NSPoint(x: 11.917000000, y: 2.992000000), controlPoint2: NSPoint(x: 12.129000000, y: 3.474000000))
    p.curve(to: NSPoint(x: 12.759321576, y: 11.239678424), controlPoint1: NSPoint(x: 10.433186096, y: 6.186256558), controlPoint2: NSPoint(x: 10.783696807, y: 9.264053655))
    p.curve(to: NSPoint(x: 20.182000000, y: 12.085000000), controlPoint1: NSPoint(x: 14.734946345, y: 13.215303193), controlPoint2: NSPoint(x: 17.812743442, y: 13.565813904))
    p.curve(to: NSPoint(x: 20.985000000, y: 12.486000000), controlPoint1: NSPoint(x: 20.526000000, y: 11.870000000), controlPoint2: NSPoint(x: 21.007000000, y: 12.081000000))
    color.setStroke(); p.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func drawHistoryClock(in bounds: NSRect, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(translationByX: bounds.midX - 7, byY: bounds.midY - 7)
    var scaled = transform
    scaled.scale(x: 14 / 24, y: 14 / 24)
    (scaled as NSAffineTransform).concat()
    let p = NSBezierPath()
    p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: 3, y: 12))
    p.curve(to: NSPoint(x: 12, y: 21), controlPoint1: NSPoint(x: 3, y: 16.97), controlPoint2: NSPoint(x: 7.03, y: 21))
    p.curve(to: NSPoint(x: 21, y: 12), controlPoint1: NSPoint(x: 16.97, y: 21), controlPoint2: NSPoint(x: 21, y: 16.97))
    p.curve(to: NSPoint(x: 12, y: 3), controlPoint1: NSPoint(x: 21, y: 7.03), controlPoint2: NSPoint(x: 16.97, y: 3))
    p.curve(to: NSPoint(x: 5.26, y: 5.74), controlPoint1: NSPoint(x: 9.47, y: 3), controlPoint2: NSPoint(x: 7.04, y: 4.04))
    p.line(to: NSPoint(x: 3, y: 8))
    p.move(to: NSPoint(x: 3, y: 3)); p.line(to: NSPoint(x: 3, y: 8)); p.line(to: NSPoint(x: 8, y: 8))
    p.move(to: NSPoint(x: 12, y: 7)); p.line(to: NSPoint(x: 12, y: 12)); p.line(to: NSPoint(x: 16, y: 14))
    color.setStroke(); p.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func drawBackArrow(in bounds: NSRect, color: NSColor) {
    let p = NSBezierPath()
    p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: bounds.midX + 6, y: bounds.midY)); p.line(to: NSPoint(x: bounds.midX - 6, y: bounds.midY))
    p.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY)); p.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 6))
    p.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY)); p.line(to: NSPoint(x: bounds.midX, y: bounds.midY - 6))
    color.setStroke(); p.stroke()
}

class GridButton: NSButton {
    var drawsGridEdges = true
    var drawsBottomEdge = true
    var invertsWhenHighlighted = true
    var needsAttention = false
    override func draw(_ dirtyRect: NSRect) {
        let selected = (state == .on || isHighlighted) && !needsAttention
        (selected ? (invertsWhenHighlighted ? panelText : selectionBackground) : panelBackground).setFill()
        NSBezierPath(rect: bounds).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: selected && invertsWhenHighlighted ? panelBackground : panelText]
        let text = title.uppercased() as NSString
        let size = text.size(withAttributes: attrs)
        if needsAttention {
            let count = title.split(separator: " ").last.map(String.init) ?? ""
            let countText = count as NSString
            let diameter: CGFloat = 19
            let circle = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            unclassifiedColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let badgeAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor(white: 0.12, alpha: 1)]
            let badge = countText
            let badgeSize = badge.size(withAttributes: badgeAttrs)
            badge.draw(at: NSPoint(x: circle.midX - badgeSize.width / 2, y: circle.midY - badgeSize.height / 2), withAttributes: badgeAttrs)
        } else if title == "☾" {
            drawWebMoon(in: bounds, color: attrs[.foregroundColor] as! NSColor, flipped: isFlipped)
        } else if title == "◷" {
            drawHistoryClock(in: bounds, color: attrs[.foregroundColor] as! NSColor)
        } else if title == "←" {
            drawBackArrow(in: bounds, color: attrs[.foregroundColor] as! NSColor)
        } else {
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        if drawsGridEdges {
            hairline(NSRect(x: bounds.width - pixel, y: 0, width: pixel, height: bounds.height))
            if drawsBottomEdge { hairline(NSRect(x: 0, y: 0, width: bounds.width, height: pixel)) }
        }
    }
}

final class AppListView: NSView {
    weak var owner: AppDelegate?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        panelBackground.setFill(); NSBezierPath(rect: bounds).fill()
        guard let owner = owner else { return }
        let rows = (owner.ledger.apps ?? [:]).sorted {
            ($0.value.lastUsed ?? 0) == ($1.value.lastUsed ?? 0) ? $0.value.seconds > $1.value.seconds : ($0.value.lastUsed ?? 0) > ($1.value.lastUsed ?? 0)
        }
        let total = rows.reduce(0) { $0 + $1.value.seconds }
        let attrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: panelText]
        if rows.isEmpty {
            ("APP USE WILL APPEAR HERE" as NSString).draw(at: NSPoint(x: 16, y: 20), withAttributes: attrs)
        }
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        for (index, row) in rows.enumerated() {
            let y = CGFloat(index * 56)
            let name = row.value.name + (row.key == owner.activeID ? " ·" : "")
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            var nameAttrs = attrs; nameAttrs[.paragraphStyle] = style
            (name as NSString).draw(in: NSRect(x: 16, y: y + 12, width: 230, height: 18), withAttributes: nameAttrs)
            let duration = owner.duration(row.value.seconds) as NSString
            duration.draw(at: NSPoint(x: 344 - duration.size(withAttributes: attrs).width, y: y + 12), withAttributes: attrs)
            NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 16, y: y + 39, width: total > 0 ? 232 * min(1, max(0, row.value.seconds / total)) : 0, height: pixel)).fill()
            hairline(NSRect(x: 264, y: y, width: pixel, height: 56))
            hairline(NSRect(x: 0, y: y + 56 - pixel, width: bounds.width, height: pixel))
        }
    }
}

final class ReviewButton: GridButton {
    var hasCategory = false
    var siteID = ""
    var mode = ""
    override func draw(_ dirtyRect: NSRect) {
        (state == .on || isHighlighted ? selectionBackground : panelBackground).setFill()
        NSBezierPath(rect: bounds).fill()
        let color: NSColor = hasCategory && state != .on ? NSColor(white: 0.4, alpha: 1) : (mode == "create" ? createColor : mode == "consume" ? consumeColor : state == .on ? panelText : NSColor(white: 0.55, alpha: 1))
        let attrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: color]
        let text = title as NSString; let size = text.size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attrs)
        if state == .on { text.draw(at: NSPoint(x: origin.x + 0.35, y: origin.y), withAttributes: attrs) }
        // Row separators belong to the list; each control owns only its left edge.
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        hairline(NSRect(x: 0, y: 0, width: pixel, height: bounds.height))
    }
}
final class ReviewListView: NSView {
    override var isFlipped: Bool { true }
}

final class HistoryListView: NSView {
    weak var owner: AppDelegate?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        panelBackground.setFill(); NSBezierPath(rect: bounds).fill()
        guard let owner = owner else { return }
        let entries = owner.historyEntries()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: NSColor.gray]
        if entries.isEmpty { ("NO HISTORY YET" as NSString).draw(at: NSPoint(x: 16, y: 14), withAttributes: labelAttrs) }
        for (index, entry) in entries.enumerated() {
            let y = CGFloat(index * 44)
            (owner.shortDay(entry.day) as NSString).draw(at: NSPoint(x: 16, y: y + 13), withAttributes: labelAttrs)
            let total = entry.create + entry.consume
            let fraction = total > 0 ? entry.create / total : 0.5
            consumeColor.setFill(); NSBezierPath(rect: NSRect(x: 84, y: y + 21, width: 164, height: 2)).fill()
            createColor.setFill(); NSBezierPath(rect: NSRect(x: 84, y: y + 21, width: 164 * fraction, height: 2)).fill()
            let create = total > 0 ? Int((fraction * 100).rounded()) : 0
            let ratio = total > 0 ? "\(create)/\(100 - create)" : "—/—"
            let ratioColor = total == 0 ? panelText : (create > 50 ? createColor : (create < 50 ? consumeColor : panelText))
            let ratioAttrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: ratioColor]
            let text = ratio as NSString
            text.draw(at: NSPoint(x: 344 - text.size(withAttributes: ratioAttrs).width, y: y + 13), withAttributes: ratioAttrs)
            hairline(NSRect(x: 0, y: y + 44 - pixel, width: bounds.width, height: pixel))
        }
    }
}

final class CaretDividerView: NSView {
    weak var panel: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let panel = panel else { return }
        let content = convert(panel.bounds, from: panel)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let bottom = content.maxY
        let height: CGFloat = 9
        let tip = bottom + height - pixel
        let edge = content.insetBy(dx: pixel / 2, dy: pixel / 2)
        let radius: CGFloat = 10
        let tangent = radius * (1 - 0.5522847498)
        let x = content.midX
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: x - height, y: edge.maxY))
        outline.line(to: NSPoint(x: edge.minX + radius, y: edge.maxY))
        outline.curve(to: NSPoint(x: edge.minX, y: edge.maxY - radius), controlPoint1: NSPoint(x: edge.minX + tangent, y: edge.maxY), controlPoint2: NSPoint(x: edge.minX, y: edge.maxY - tangent))
        outline.line(to: NSPoint(x: edge.minX, y: edge.minY + radius))
        outline.curve(to: NSPoint(x: edge.minX + radius, y: edge.minY), controlPoint1: NSPoint(x: edge.minX, y: edge.minY + tangent), controlPoint2: NSPoint(x: edge.minX + tangent, y: edge.minY))
        outline.line(to: NSPoint(x: edge.maxX - radius, y: edge.minY))
        outline.curve(to: NSPoint(x: edge.maxX, y: edge.minY + radius), controlPoint1: NSPoint(x: edge.maxX - tangent, y: edge.minY), controlPoint2: NSPoint(x: edge.maxX, y: edge.minY + tangent))
        outline.line(to: NSPoint(x: edge.maxX, y: edge.maxY - radius))
        outline.curve(to: NSPoint(x: edge.maxX - radius, y: edge.maxY), controlPoint1: NSPoint(x: edge.maxX, y: edge.maxY - tangent), controlPoint2: NSPoint(x: edge.maxX - tangent, y: edge.maxY))
        outline.line(to: NSPoint(x: x + height, y: edge.maxY))
        outline.curve(to: NSPoint(x: x, y: tip),
                      controlPoint1: NSPoint(x: x + height * 0.55, y: edge.maxY),
                      controlPoint2: NSPoint(x: x + height * 0.45, y: tip))
        outline.curve(to: NSPoint(x: x - height, y: edge.maxY),
                      controlPoint1: NSPoint(x: x - height * 0.45, y: tip),
                      controlPoint2: NSPoint(x: x - height * 0.55, y: edge.maxY))
        outline.close()
        // Fill only the caret area from the exact outline used for its stroke.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: content.minX, y: bottom, width: content.width, height: height + 1)).addClip()
        panelBackground.setFill(); outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        gridColor.setStroke(); outline.lineWidth = pixel; outline.stroke()
    }
}

final class RatioView: NSView {
    private var caretDivider: CaretDividerView?
    weak var owner: AppDelegate?
    var selectedTab = 0
    var reviewingPending = false
    let notifications = GridButton(title: "", target: nil, action: nil)
    let ratioTab = GridButton(title: "Ratio", target: nil, action: nil)
    let appsTab = GridButton(title: "Apps", target: nil, action: nil)
    let appScroll = NSScrollView()
    let appList = AppListView(frame: .zero)
    let reviewList = ReviewListView(frame: .zero)
    let reviewScroll = NSScrollView()
    let historyScroll = NSScrollView()
    let historyList = HistoryListView(frame: .zero)
    var showingHistory = false
    let reviewButton = GridButton(title: "Review sites", target: nil, action: nil)
    var reviewSignature = ""
    var showingApps: Bool { selectedTab == 1 }
    let title = NSTextField(labelWithString: "TODAY")
    let totals = NSTextField(labelWithString: "")
    let context = NSTextField(wrappingLabelWithString: "")
    let trackedTotal = NSTextField(labelWithString: "")
    let note = NSTextField(wrappingLabelWithString: "")
    let consume = GridButton(title: "↓ Consume", target: nil, action: #selector(AppDelegate.chooseConsume))
    let create = GridButton(title: "↑ Create", target: nil, action: #selector(AppDelegate.chooseCreate))
    let pause = GridButton(title: "Pause", target: nil, action: #selector(AppDelegate.togglePause))
    let history = GridButton(title: "◷", target: nil, action: nil)
    let forget = GridButton(title: "Reset", target: nil, action: #selector(AppDelegate.resetAll))
    let theme = GridButton(title: "☀", target: nil, action: #selector(toggleTheme))
    let quit = GridButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = panelBackground.cgColor
        for button in [ratioTab, appsTab, consume, create, pause, history, forget, quit, theme] {
            button.font = interfaceFont; button.isBordered = false; button.setButtonType(.momentaryPushIn); addSubview(button)
        }
        ratioTab.target = self; ratioTab.action = #selector(showRatio)
        appsTab.target = self; appsTab.action = #selector(showApps)
        ratioTab.frame = NSRect(x: 0, y: 396, width: 180, height: 44)
        appsTab.frame = NSRect(x: 180, y: 396, width: 180, height: 44)
        for label in [title, totals, context, note] { label.font = interfaceFont; label.textColor = panelText; addSubview(label) }
        totals.font = .monospacedSystemFont(ofSize: 48, weight: .regular)
        totals.alignment = .center
        title.frame = NSRect(x: 16, y: 365, width: 260, height: 18)
        let brand = NSTextField(labelWithString: "RATIO")
        brand.isHidden = true; title.isHidden = true
        brand.font = interfaceFont; brand.textColor = .gray; brand.alignment = .right
        brand.frame = NSRect(x: 276, y: 365, width: 68, height: 18); addSubview(brand)
        let notificationPixel = 1 / (NSScreen.main?.backingScaleFactor ?? 2)
        notifications.frame = NSRect(x: 272 + notificationPixel, y: 264 + notificationPixel, width: 88 - notificationPixel, height: 44 - notificationPixel)
        notifications.drawsGridEdges = false
        notifications.target = self; notifications.action = #selector(togglePending)
        notifications.font = interfaceFont; notifications.isBordered = false
        addSubview(notifications)
        totals.frame = NSRect(x: 16, y: 269, width: 328, height: 65)
        context.frame = NSRect(x: 16, y: 277, width: 156, height: 18)
        context.textColor = .gray
        trackedTotal.font = interfaceFont; trackedTotal.textColor = .gray; trackedTotal.alignment = .right
        trackedTotal.frame = NSRect(x: 180, y: 277, width: 84, height: 18)
        addSubview(trackedTotal)
        note.frame = NSRect(x: 16, y: 53, width: 328, height: 46)
        create.frame = NSRect(x: 0, y: 108, width: 180, height: 44)
        consume.frame = NSRect(x: 180, y: 108, width: 180, height: 44)
        pause.frame = NSRect(x: 0, y: 0, width: 44, height: 44)
        history.frame = NSRect(x: 44, y: 0, width: 44, height: 44)
        history.target = self; history.action = #selector(toggleHistory)
        history.invertsWhenHighlighted = false
        history.toolTip = "History"; history.setAccessibilityLabel("Show history")
        forget.frame = NSRect(x: 88, y: 0, width: 114, height: 44)
        quit.frame = NSRect(x: 202, y: 0, width: 114, height: 44)
        theme.frame = NSRect(x: 316, y: 0, width: 44, height: 44)
        theme.target = self; theme.drawsGridEdges = false; theme.invertsWhenHighlighted = false
        pause.drawsBottomEdge = false; history.drawsBottomEdge = false; forget.drawsBottomEdge = false
        quit.drawsBottomEdge = false
        appScroll.frame = NSRect(x: 0, y: 108, width: 360, height: 244)
        appScroll.drawsBackground = false; appScroll.hasVerticalScroller = true; appScroll.scrollerStyle = .overlay
        appScroll.documentView = appList; addSubview(appScroll); appScroll.isHidden = true
        reviewScroll.frame = NSRect(x: 0, y: 44, width: 360, height: 220); reviewScroll.drawsBackground = false
        reviewScroll.hasVerticalScroller = true; reviewScroll.scrollerStyle = .overlay
        reviewScroll.documentView = reviewList; addSubview(reviewScroll); reviewScroll.isHidden = true
        historyScroll.frame = NSRect(x: 0, y: 44, width: 360, height: 220); historyScroll.drawsBackground = false
        historyScroll.hasVerticalScroller = true; historyScroll.scrollerStyle = .overlay
        historyList.owner = owner; historyScroll.documentView = historyList; addSubview(historyScroll); historyScroll.isHidden = true
        reviewButton.frame = NSRect(x: 0, y: 44, width: 360, height: 64)
        reviewButton.target = self; reviewButton.action = #selector(showReview); addSubview(reviewButton)
        reviewButton.isHidden = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The native popover draws its arrow outside our content view.
        // Color that backing surface too, so the arrow matches the panel.
        window?.backgroundColor = panelBackground
        window?.hasShadow = false
        var ancestor = superview
        while let view = ancestor {
            if let effect = view as? NSVisualEffectView {
                effect.state = .inactive
                effect.wantsLayer = true
                effect.layer?.backgroundColor = panelBackground.cgColor
            }
            ancestor = view.superview
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.window != nil else { return }
            self.window?.hasShadow = false
            self.window?.invalidateShadow()
            var surface: NSView = self
            while let parent = surface.superview { surface = parent }
            self.caretDivider?.removeFromSuperview()
            let divider = CaretDividerView(frame: surface.bounds)
            divider.panel = self
            divider.autoresizingMask = [.width, .height]
            surface.addSubview(divider, positioned: .above, relativeTo: nil)
            self.caretDivider = divider
        }
    }
    @objc func toggleTheme() {
        lightMode.toggle(); UserDefaults.standard.set(lightMode, forKey: "lightMode")
        applyTheme(); owner?.render()
    }
    func applyTheme() {
        layer?.backgroundColor = panelBackground.cgColor
        window?.backgroundColor = panelBackground
        var ancestor = superview
        while let view = ancestor {
            if view is NSVisualEffectView { view.layer?.backgroundColor = panelBackground.cgColor }
            ancestor = view.superview
        }
        theme.title = lightMode ? "☾" : "☀"
        theme.setAccessibilityLabel(lightMode ? "Switch to dark mode" : "Switch to light mode")
        theme.toolTip = lightMode ? "Dark mode" : "Light mode"
        reviewSignature = ""; caretDivider?.needsDisplay = true
        notifications.needsDisplay = true; needsDisplay = true
    }
    @objc func togglePending() {
        reviewingPending.toggle()
        reviewScroll.contentView.scroll(to: .zero)
        owner?.render()
    }
    @objc func showReview() { selectedTab = 2; owner?.render() }
    @objc func showRatio() { selectedTab = 0; owner?.render() }
    @objc func showApps() { selectedTab = 1; owner?.render() }
    @objc func toggleHistory() {
        showingHistory.toggle()
        history.title = showingHistory ? "←" : "◷"
        history.setAccessibilityLabel(showingHistory ? "Back to activity" : "Show history")
        history.toolTip = showingHistory ? "Back to activity" : "History"
        owner?.render()
    }
    func refreshApps() {
        selectedTab = 0
        ratioTab.isHidden = true; appsTab.isHidden = true
        totals.isHidden = true; context.isHidden = false
        consume.isHidden = true; create.isHidden = true
        appScroll.isHidden = true; reviewScroll.isHidden = showingHistory
        historyScroll.isHidden = !showingHistory
        reviewButton.isHidden = true; note.isHidden = true
        history.state = showingHistory ? .on : .off
        if showingHistory {
            context.stringValue = "HISTORY"
            notifications.isHidden = true
            historyList.owner = owner
            let count = owner?.historyEntries().count ?? 0
            trackedTotal.stringValue = "\(count) DAY\(count == 1 ? "" : "S")"
            trackedTotal.frame = NSRect(x: 180, y: 277, width: 164, height: 18)
            historyList.setFrameSize(NSSize(width: 360, height: max(220, count * 44)))
            historyList.needsDisplay = true
        } else {
            notifications.isHidden = false
            trackedTotal.frame = NSRect(x: 180, y: 277, width: 84, height: 18)
        }
        let count = owner?.pendingSites.count ?? 0
        notifications.title = count > 0 ? "! \(count)" : "✓"
        notifications.needsAttention = count > 0
        notifications.state = reviewingPending ? .on : .off
        notifications.toolTip = count > 0 ? "\(count) app\(count == 1 ? " needs" : "s need") categorizing" : "All apps categorized"
        notifications.setAccessibilityLabel(notifications.toolTip)
        notifications.needsDisplay = true
        let rows = owner?.activityRows(pendingOnly: reviewingPending) ?? []
        func selectedMode(_ id: String) -> String? { owner?.effectiveMode(id) }
        let signature = rows.map { [$0.id, $0.name, $0.detail, selectedMode($0.id) ?? "?", String($0.active)].joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
            + String(reviewingPending) + (owner?.expandedBrowsers.sorted().joined() ?? "")
        if signature != reviewSignature {
            reviewSignature = signature
            let scrollOrigin = reviewScroll.contentView.bounds.origin
            reviewList.subviews.forEach { $0.removeFromSuperview() }
            if rows.isEmpty {
                let empty = NSTextField(labelWithString: reviewingPending ? "All caught up." : "Activity will appear here.")
                empty.font = interfaceFont; empty.textColor = panelText
                empty.frame = NSRect(x: 16, y: 13, width: 328, height: 18)
                reviewList.addSubview(empty)
            }
            for (i, row) in rows.enumerated() {
                let y = CGFloat(i * 44)
                let child = row.browserID != nil
                let labelX: CGFloat = row.expandable ? 40 : child ? 32 : 16
                if row.expandable {
                    let expanded = owner?.expandedBrowsers.contains(row.id) == true || reviewingPending
                    let disclosure = ReviewButton(title: expanded ? "⌄" : "›", target: owner, action: #selector(AppDelegate.toggleBrowser(_:)))
                    disclosure.siteID = row.id; disclosure.isBordered = false
                    disclosure.frame = NSRect(x: 0, y: y, width: 40, height: 44)
                    disclosure.toolTip = (expanded ? "Collapse " : "Expand ") + row.name
                    disclosure.setAccessibilityLabel(disclosure.toolTip)
                    disclosure.isEnabled = !reviewingPending
                    reviewList.addSubview(disclosure)
                }
                let label = NSTextField(labelWithString: row.name)
                label.font = interfaceFont; label.textColor = row.message ? .secondaryLabelColor : selectedMode(row.id) == nil ? unclassifiedColor : panelText
                label.lineBreakMode = .byTruncatingTail
                label.toolTip = row.message ? row.detail : row.name + (child ? " · " + (owner?.ledger.apps?[row.id]?.name ?? "") : "")
                label.frame = NSRect(x: labelX, y: y + (row.detail.isEmpty ? 13 : 5), width: (row.message ? 344 : child ? 151 : 177) - labelX, height: 18)
                reviewList.addSubview(label)
                if !row.detail.isEmpty {
                    let detail = NSTextField(labelWithString: row.detail)
                    detail.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
                    detail.textColor = .gray; detail.lineBreakMode = .byTruncatingTail; detail.toolTip = row.detail
                    detail.frame = NSRect(x: labelX, y: y + 25, width: (row.message ? 344 : 224) - labelX, height: 14)
                    reviewList.addSubview(detail)
                }
                if !row.message {
                    let time = NSTextField(labelWithString: "")
                    time.identifier = NSUserInterfaceItemIdentifier(row.id)
                    time.font = interfaceFont; time.textColor = panelText; time.alignment = .right
                    time.frame = NSRect(x: child ? 153 : 178, y: y + 13, width: child ? 71 : 86, height: 18)
                    reviewList.addSubview(time)
                    if child {
                        let overridden = owner?.rules[row.id] != nil
                        let inherit = ReviewButton(title: overridden ? "↩" : "·", target: owner, action: #selector(AppDelegate.inheritPage(_:)))
                        inherit.siteID = row.id; inherit.isBordered = false; inherit.isEnabled = overridden
                        inherit.frame = NSRect(x: 228, y: y, width: 44, height: 44)
                        inherit.toolTip = overridden ? "Use browser default" : "Inherits browser default"
                        inherit.setAccessibilityLabel("Use browser default for " + row.name)
                        reviewList.addSubview(inherit)
                    }
                    for (j, mode) in ["create", "consume"].enumerated() {
                        let button = ReviewButton(title: mode == "consume" ? "↓" : "↑", target: owner, action: #selector(AppDelegate.reviewSite(_:)))
                        button.siteID = row.id; button.mode = mode; button.font = interfaceFont
                        button.state = selectedMode(row.id) == mode ? .on : .off
                        button.hasCategory = selectedMode(row.id) != nil
                        button.isBordered = false
                        button.toolTip = (mode == "create" ? "Creating" : "Consuming") + (row.expandable ? " · browser default" : child ? " · this page only" : "")
                        button.setAccessibilityLabel((mode == "create" ? "Create: " : "Consume: ") + row.name)
                        button.frame = NSRect(x: 272 + CGFloat(j * 44), y: y, width: 44, height: 44)
                        reviewList.addSubview(button)
                    }
                }
                let pixel = 1 / (window?.backingScaleFactor ?? 2)
                let line = NSView(frame: NSRect(x: child ? 32 : 0, y: y + 44 - pixel, width: child ? 328 : 360, height: pixel))
                line.wantsLayer = true; line.layer?.backgroundColor = gridColor.cgColor; reviewList.addSubview(line)
            }
            reviewList.setFrameSize(NSSize(width: 360, height: max(220, rows.count * 44)))
            reviewScroll.contentView.scroll(to: NSPoint(x: 0, y: min(scrollOrigin.y, max(0, reviewList.frame.height - reviewScroll.contentView.bounds.height))))
            reviewScroll.reflectScrolledClipView(reviewScroll.contentView)
        }
        let rowMap = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for case let time as NSTextField in reviewList.subviews {
            if let id = time.identifier?.rawValue, let row = rowMap[id] {
                let active = row.active && owner?.paused == false && owner?.idle == false && owner?.sleeping == false
                let text = (active ? "● " : "") + (owner?.duration(row.seconds) ?? "")
                let value = NSMutableAttributedString(string: text, attributes: [.font: interfaceFont, .foregroundColor: panelText])
                if active {
                    value.addAttributes([.foregroundColor: selectedMode(id) == "consume" ? consumeColor : createColor, .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .baselineOffset: 2], range: NSRange(location: 0, length: 1))
                }
                let alignment = NSMutableParagraphStyle(); alignment.alignment = .right
                value.addAttribute(.paragraphStyle, value: alignment, range: NSRange(location: 0, length: value.length))
                time.attributedStringValue = value
            }
        }
        ratioTab.state = selectedTab == 0 ? .on : .off; appsTab.state = selectedTab == 0 ? .off : .on
        let height = max(244, (owner?.ledger.apps?.count ?? 0) * 56)
        appList.setFrameSize(NSSize(width: 360, height: height)); appList.needsDisplay = true
        for button in [ratioTab, appsTab, consume, create, pause, history, forget, quit, theme] { button.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        for y: CGFloat in [44, 264, 352] { hairline(NSRect(x: 0, y: y, width: 360, height: pixel)) }
        // Dividers are inset one physical pixel into adjacent cells to remain visible.
        hairline(NSRect(x: 272, y: 264, width: pixel, height: 44))
        guard let o = owner, selectedTab == 0 else { return }
        for y: CGFloat in [308, 352] { hairline(NSRect(x: 0, y: y, width: 360, height: pixel)) }

        let total = o.ledger.consume + o.ledger.create
        let fraction = total > 0 ? o.ledger.create / total : 0.5
        consumeColor.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 308, width: 360, height: pixel)).fill()
        createColor.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 308, width: 360 * fraction, height: pixel)).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: interfaceFont, .foregroundColor: panelText]
        let basisPoints = total > 0 ? Int((fraction * 10000).rounded()) : 0
        let consumeValue = total > 0 ? String(format: "%.2f%%", Double(10000 - basisPoints) / 100) : "—"
        let createValue = total > 0 ? String(format: "%.2f%%", Double(basisPoints) / 100) : "—"
        let consumeText = NSMutableAttributedString(string: "↓ " + consumeValue + " CONSUMING", attributes: attrs)
        consumeText.addAttribute(.foregroundColor, value: consumeColor, range: NSRange(location: 0, length: 2 + (consumeValue as NSString).length))
        consumeText.draw(at: NSPoint(x: 196, y: 323))
        let createText = NSMutableAttributedString(string: "↑ " + createValue + " CREATING", attributes: attrs)
        createText.addAttribute(.foregroundColor, value: createColor, range: NSRange(location: 0, length: 2 + (createValue as NSString).length))
        createText.draw(at: NSPoint(x: 16, y: 323))
    }
}

struct UpdateCredential: Codable {
    let token: String
    let email: String
    static let service = "com.visualizevalue.ratio.updates"
    static func load() -> UpdateCredential? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: "device", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as [CFString: Any] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func store() -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        let key = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: "device"] as [CFString: Any]
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = key; item[kSecValueData] = data; item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

final class CodeInputView: NSView, NSTextFieldDelegate {
    var fields: [NSTextField] = []
    var onSubmit: (() -> Void)?
    var stringValue: String { fields.map { $0.stringValue }.joined() }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for index in 0..<6 {
            let field = NSTextField(frame: NSRect(x: CGFloat(index) * 42, y: 5, width: 34, height: 20))
            field.isEditable = true; field.isSelectable = true
            field.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium); field.alignment = .center
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
            field.backgroundColor = selectionBackground; field.textColor = panelText
            field.focusRingType = .none; field.delegate = self
            field.setAccessibilityLabel("Code digit \(index + 1) of 6")
            fields.append(field); addSubview(field)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        selectionBackground.setFill()
        for index in 0..<6 {
            NSRect(x: CGFloat(index) * 42, y: 0, width: 34, height: 30).fill()
        }
    }
    func clear() { fields.forEach { $0.stringValue = "" } }
    func focus() { window?.makeFirstResponder(fields[0]) }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let index = fields.firstIndex(of: field) else { return }
        let digits = field.stringValue.filter { $0 >= "0" && $0 <= "9" }
        if digits.isEmpty { field.stringValue = ""; return }
        // A full pasted code fills every slot, regardless of the current focus.
        let start = digits.count >= 6 ? 0 : index
        let characters = Array(digits.prefix(6))
        for (offset, digit) in characters.enumerated() where start + offset < 6 {
            fields[start + offset].stringValue = String(digit)
        }
        let next = min(5, start + characters.count)
        window?.makeFirstResponder(fields[next]); fields[next].selectText(nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onSubmit?(); return true }
        if selector == #selector(NSResponder.deleteBackward(_:)),
           let field = control as? NSTextField, field.stringValue.isEmpty,
           let index = fields.firstIndex(of: field), index > 0 {
            fields[index - 1].stringValue = ""; window?.makeFirstResponder(fields[index - 1]); return true
        }
        return false
    }
}

final class UpdateSignInView: NSView {
    let heading = NSTextField(labelWithString: "SIGN IN FOR UPDATES")
    let detail = NSTextField(wrappingLabelWithString: "Use the email you purchased Ratio with.")
    let input = NSTextField()
    var emailBackground: NSView!
    let codeInput = CodeInputView(frame: NSRect(x: 24, y: 175, width: 244, height: 30))
    let message = NSTextField(wrappingLabelWithString: "")
    let submit = GridButton(title: "SEND CODE", target: nil, action: nil)
    let back = GridButton(title: "LATER", target: nil, action: nil)
    var onClose: (() -> Void)?
    var onVerified: ((UpdateCredential) -> Void)?
    var challenge: String?
    var busy = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: lightMode ? .aqua : .darkAqua)
        wantsLayer = true; layer?.backgroundColor = panelBackground.cgColor
        for label in [heading, detail, message] { label.font = interfaceFont; label.textColor = panelText; addSubview(label) }
        heading.frame = NSRect(x: 24, y: 287, width: 312, height: 22)
        detail.frame = NSRect(x: 24, y: 225, width: 312, height: 44)
        emailBackground = NSView(frame: NSRect(x: 24, y: 179, width: 312, height: 26))
        emailBackground.wantsLayer = true; emailBackground.layer?.backgroundColor = selectionBackground.cgColor
        addSubview(emailBackground)
        input.isEditable = true; input.isSelectable = true
        input.isBezeled = false; input.isBordered = false; input.drawsBackground = false
        input.frame = NSRect(x: 28, y: 182, width: 304, height: 20)
        input.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular); input.textColor = panelText; input.backgroundColor = selectionBackground
        input.placeholderAttributedString = NSAttributedString(string: "Purchase email", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor(calibratedWhite: lightMode ? 0.40 : 0.62, alpha: 1)]); input.focusRingType = .none
        input.target = self; input.action = #selector(send); addSubview(input)
        codeInput.isHidden = true; codeInput.onSubmit = { [weak self] in self?.send() }; addSubview(codeInput)
        message.frame = NSRect(x: 24, y: 65, width: 312, height: 76); message.textColor = .gray
        submit.frame = NSRect(x: 0, y: 0, width: 240, height: 44); back.frame = NSRect(x: 240, y: 0, width: 120, height: 44)
        for b in [submit, back] { b.isBordered = false; b.setButtonType(.momentaryPushIn); b.target = self; addSubview(b) }
        submit.action = #selector(send); back.action = #selector(goBack)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func goBack() {
        guard !busy else { return }
        if challenge != nil {
            challenge = nil; codeInput.isHidden = true; codeInput.clear(); input.isHidden = false; emailBackground.isHidden = false
            window?.makeFirstResponder(input)
            heading.stringValue = "SIGN IN FOR UPDATES"; detail.stringValue = "Use the email you purchased Ratio with."
            input.stringValue = ""; input.placeholderAttributedString = NSAttributedString(string: "Purchase email", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor(calibratedWhite: lightMode ? 0.40 : 0.62, alpha: 1)]); submit.title = "SEND CODE"; back.title = "LATER"; message.stringValue = ""
        } else { onClose?() }
    }
    @objc func send() {
        guard !busy else { return }
        let value = challenge == nil ? input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : codeInput.stringValue
        if challenge != nil && value.range(of: "^[0-9]{6}$", options: .regularExpression) == nil { message.stringValue = "Enter the six-digit code from your email."; return }
        if challenge == nil && (value.count > 254 || value.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) == nil) { message.stringValue = "Enter your purchase email."; return }
        let verifying = challenge != nil
        let body = verifying ? ["challengeId": challenge!, "code": value] : ["email": value]
        var req = URLRequest(url: URL(string: "https://visualizevalue.com/api/ratio/auth/" + (verifying ? "verify" : "request"))!)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        busy = true; submit.isEnabled = false; back.isEnabled = false; message.stringValue = verifying ? "Checking code…" : "Sending code…"
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false; self.submit.isEnabled = true; self.back.isEnabled = true
                guard error == nil, let data = data, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.message.stringValue = "Couldn’t connect. Please try again."; return
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.message.stringValue = result["error"] as? String ?? "Please try again shortly."; return
                }
                if verifying {
                    guard let token = result["token"] as? String, let email = result["email"] as? String,
                        token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { self.message.stringValue = "Please request a new code."; return }
                    let credential = UpdateCredential(token: token, email: email)
                    guard credential.store() else { self.message.stringValue = "Couldn’t save your sign-in to Keychain. Please request a new code."; return }
                    self.onVerified?(credential)
                } else {
                    guard let id = result["challengeId"] as? String else { self.message.stringValue = "Please try again."; return }
                    self.challenge = id; self.heading.stringValue = "CHECK YOUR EMAIL"
                    self.detail.stringValue = "If this email has a Ratio purchase, a six-digit code is on its way."
                    self.input.isHidden = true; self.emailBackground.isHidden = true; self.codeInput.clear(); self.codeInput.isHidden = false; self.submit.title = "VERIFY CODE"; self.back.title = "BACK"
                    self.message.stringValue = "Code expires in 10 minutes. Check spam, or go back to request another code."
                    self.codeInput.focus()
                }
            }
        }.resume()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var updaterController: SPUStandardUpdaterController!
    var updaterStarted = false
    var signInView: UpdateSignInView?
    var ledger = Ledger(day: dayKey())
    var resetUndo: ResetSnapshot?
    var resetUndoTimer: Timer?
    var history: [DaySummary] = []
    var rules: [String: String] = [:]
    var status: NSStatusItem!
    let popover = NSPopover()
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    var panel: RatioView!
    var timer: Timer?
    var activeID = ""
    var activeName = "No active app"
    var browserID: String?
    var browserName = ""
    var checkingBrowsers = Set<String>()
    var expandedBrowsers = Set<String>()
    var browserSnapshots: [String: BrowserSnapshot] = [:]
    var knownPages: [String: BrowserPage] = [:]
    var browserGeneration = 0
    let browserQueue = DispatchQueue(label: "ratio.browser-reader", qos: .utility)
    let browsers = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia"]
    let consumeSites = ["x.com", "twitter.com", "youtube.com", "reddit.com", "instagram.com", "tiktok.com", "netflix.com"]
    let createSites = ["figma.com", "docs.google.com", "canva.com"]
    var mode: String?
    var switched = Date()
    var lastTick = Date()
    var lastPrompt = Date.distantPast
    var prompted = Set<String>()
    var paused = false
    var sleeping = false
    var idle = false
    var ticks = 0
    var activeSeconds: Double = 0
    var telemetrySeconds: Double = 0
    var telemetryEnabled = true
    var telemetryInstallID = ""
    var lastTelemetryReport = Date.distantPast
    var chromeSessionSites = Set<String>()
    var reviewWork: DispatchWorkItem?
    var pendingSites: [(key: String, value: AppUsage)] {
        (ledger.apps ?? [:]).filter { ($0.value.unclassified ?? 0) >= 1 }.sorted { ($0.value.lastUsed ?? 0) > ($1.value.lastUsed ?? 0) }
    }
    @objc func reviewSite(_ button: ReviewButton) {
        tick()
        setClassification(button.siteID, value: button.mode)
        if pendingSites.isEmpty { panel.reviewingPending = false }
        save(); render()
    }
    func effectiveMode(_ id: String) -> String? {
        if let explicit = rules[id] { return explicit }
        if let parent = ledger.apps?[id]?.browserID ?? knownPages[id]?.browserID {
            return rules[parent] ?? builtIns[parent]
        }
        return builtIns[id] ?? (id.hasPrefix("site:") ? siteMode(String(id.dropFirst(5))) : nil)
    }
    func setClassification(_ id: String, value: String?) {
        let previous = effectiveMode(id)
        rules[id] = value
        ledger.classifyPending(id, mode: effectiveMode(id), previousMode: previous)
        if browsers.contains(id) {
            // Parent totals are computed from children, never recorded a second time.
            for (child, usage) in ledger.apps ?? [:] where usage.browserID == id && rules[child] == nil {
                ledger.classifyPending(child, mode: effectiveMode(child))
            }
        }
        mode = effectiveMode(activeID)
    }
    @objc func inheritPage(_ button: ReviewButton) {
        tick(); setClassification(button.siteID, value: nil); save(); render()
    }
    @objc func toggleBrowser(_ button: ReviewButton) {
        if expandedBrowsers.contains(button.siteID) { expandedBrowsers.remove(button.siteID) }
        else { expandedBrowsers.insert(button.siteID); checkBrowser(button.siteID) }
        defaults.set(Array(expandedBrowsers), forKey: "expandedBrowsers")
        render()
    }
    func activityRows(pendingOnly: Bool) -> [ActivityRow] {
        let entries = ledger.apps ?? [:]
        var parents = entries.filter { $0.value.browserID == nil }
        for usage in entries.values {
            if let id = usage.browserID, parents[id] == nil {
                parents[id] = AppUsage(name: usage.browserName ?? id)
            }
        }
        func children(_ id: String) -> [(key: String, value: AppUsage)] {
            let order = Dictionary(uniqueKeysWithValues: (browserSnapshots[id]?.pages ?? []).enumerated().map { ($0.element.id, $0.offset) })
            return entries.filter { $0.value.browserID == id && ($0.value.seconds > 0 || order[$0.key] != nil) }.sorted {
                let a = order[$0.key] ?? Int.max, b = order[$1.key] ?? Int.max
                if a != b { return a < b }
                return ($0.value.lastUsed ?? 0) == ($1.value.lastUsed ?? 0) ? $0.key < $1.key : ($0.value.lastUsed ?? 0) > ($1.value.lastUsed ?? 0)
            }
        }
        func lastUsed(_ id: String) -> Double {
            max(entries[id]?.lastUsed ?? 0, entries.values.filter { $0.browserID == id }.map { $0.lastUsed ?? 0 }.max() ?? 0)
        }
        let sorted = parents.sorted {
            lastUsed($0.key) == lastUsed($1.key) ? $0.key < $1.key : lastUsed($0.key) > lastUsed($1.key)
        }
        var rows: [ActivityRow] = []
        for (id, usage) in sorted {
            let allChildren = children(id)
            let visibleChildren = allChildren.filter { !pendingOnly || ($0.value.unclassified ?? 0) >= 1 }
            guard !pendingOnly || (usage.unclassified ?? 0) >= 1 || !visibleChildren.isEmpty else { continue }
            let isBrowser = browsers.contains(id)
            let openIDs = Set(browserSnapshots[id]?.pages.map { $0.id } ?? [])
            let detail = isBrowser ? (browserSnapshots[id] == nil ? "Expand to read pages" : "\(openIDs.count) open page\(openIDs.count == 1 ? "" : "s") · default") : ""
            rows.append(ActivityRow(id: id, name: usage.name, detail: detail,
                seconds: usage.seconds + allChildren.reduce(0) { $0 + $1.value.seconds },
                expandable: isBrowser, active: activeID == id || entries[activeID]?.browserID == id))
            guard isBrowser && (expandedBrowsers.contains(id) || pendingOnly) else { continue }
            if let error = browserSnapshots[id]?.error {
                rows.append(ActivityRow(id: "message:" + id, name: "Tabs unavailable", detail: error, seconds: 0, browserID: id, message: true))
            } else if visibleChildren.isEmpty {
                rows.append(ActivityRow(id: "message:" + id, name: checkingBrowsers.contains(id) ? "Reading tabs…" : "No web pages open", detail: "Only the active page counts toward time.", seconds: 0, browserID: id, message: true))
            }
            for (child, page) in visibleChildren {
                let overridden = rules[child] != nil
                let state = openIDs.contains(child) ? "" : "Earlier · "
                rows.append(ActivityRow(id: child, name: knownPages[child]?.title ?? page.name,
                    detail: state + (overridden ? "Page override" : "Inherits " + usage.name),
                    seconds: page.seconds, browserID: id, active: child == activeID))
            }
        }
        return rows
    }
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }
    let builtIns: [String: String] = [
        "com.apple.dt.Xcode": "create", "com.microsoft.VSCode": "create", "com.todesktop.230313mzl4w4u92": "create",
        "com.figma.Desktop": "create", "com.adobe.Photoshop": "create", "com.adobe.Illustrator": "create",
        "com.apple.iWork.Pages": "create", "com.apple.iWork.Keynote": "create", "com.apple.iWork.Numbers": "create",
        "com.apple.FinalCut": "create", "com.apple.garageband10": "create", "com.apple.Logic10": "create",
        "com.apple.TV": "consume", "com.apple.iBooksX": "consume", "com.apple.news": "consume"
    ]
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = defaults.data(forKey: "ledger"), let saved = try? JSONDecoder().decode(Ledger.self, from: data) { ledger = saved }
        if let data = defaults.data(forKey: "history"), let saved = try? JSONDecoder().decode([DaySummary].self, from: data) { history = saved }
        rules = (defaults.dictionary(forKey: "rules") as? [String: String] ?? [:]).filter { $0.value != "neutral" }
        expandedBrowsers = Set(defaults.stringArray(forKey: "expandedBrowsers") ?? [])
        telemetrySeconds = defaults.double(forKey: "anonymousTrackedSeconds")
        telemetryEnabled = defaults.object(forKey: "anonymousTotalsEnabled") == nil || defaults.bool(forKey: "anonymousTotalsEnabled")
        telemetryInstallID = defaults.string(forKey: "anonymousInstallID") ?? UUID().uuidString.lowercased()
        defaults.set(telemetryInstallID, forKey: "anonymousInstallID")
        // Migrate existing per-app history to explicit category contributions.
        if let history = ledger.apps, history.values.contains(where: { $0.createSeconds == nil || $0.consumeSeconds == nil }) {
            let attributed = history.values.reduce(0) { $0 + max(0, $1.seconds - ($1.unclassified ?? 0)) }
            let legacy = max(0, ledger.create + ledger.consume - attributed)
            let fraction = ledger.create + ledger.consume > 0 ? ledger.create / (ledger.create + ledger.consume) : 0
            ledger.create = legacy * fraction; ledger.consume = legacy * (1 - fraction)
            for (id, var usage) in history {
                let category = effectiveMode(id)
                let classified = max(0, usage.seconds - (usage.unclassified ?? 0))
                usage.createSeconds = usage.createSeconds ?? (category == "create" ? classified : 0)
                usage.consumeSeconds = usage.consumeSeconds ?? (category == "consume" ? classified : 0)
                ledger.create += usage.createSeconds ?? 0
                ledger.consume += usage.consumeSeconds ?? 0
                ledger.apps?[id] = usage
            }
        }

        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        if let credential = UpdateCredential.load() {
            updaterController.updater.httpHeaders = ["Authorization": "Bearer " + credential.token]
            do {
                try updaterController.updater.start(); updaterStarted = true
                enableAutomaticUpdates()
            } catch { NSLog("Ratio updater could not start") }
        }
        rollover()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.target = self; status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status.button?.font = interfaceFont
        let controller = NSViewController()
        panel = RatioView(frame: NSRect(x: 0, y: 0, width: 360, height: 352)); panel.owner = self
        for button in [panel.consume, panel.create, panel.pause, panel.forget] { button.target = self }
        controller.view = panel; popover.contentViewController = controller; popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self = self, self.popover.isShown else { return event }
            if event.window !== self.panel.window && event.window !== self.status.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(activated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(sleepNow), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(sleepNow), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(wakeNow), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(wakeNow), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        updateApp(NSWorkspace.shared.frontmostApplication)
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        panel.applyTheme(); render(); showPopover(); checkBrowser()
        reportTelemetry()
        if UpdateCredential.load() == nil { showUpdateSignIn() }
    }
    func rollover() {
        let today = dayKey()
        if ledger.day != today {
            if ledger.create + ledger.consume > 0 {
                history.removeAll { $0.day == ledger.day }
                history.append(DaySummary(day: ledger.day, create: ledger.create, consume: ledger.consume))
                history = Array(history.sorted { $0.day > $1.day }.prefix(30))
            }
            ledger = Ledger(day: today); save()
        }
    }
    func save() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: "ledger") }
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "history") }
        defaults.set(rules, forKey: "rules")
        defaults.set(telemetrySeconds, forKey: "anonymousTrackedSeconds")
    }
    func historyEntries() -> [DaySummary] {
        var entries = history.filter { $0.day != ledger.day }
        if ledger.create + ledger.consume > 0 { entries.append(DaySummary(day: ledger.day, create: ledger.create, consume: ledger.consume)) }
        return Array(entries.sorted { $0.day > $1.day }.prefix(30))
    }
    func shortDay(_ value: String) -> String {
        let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: value) else { return value }
        let output = DateFormatter(); output.locale = Locale(identifier: "en_US_POSIX"); output.dateFormat = value == dayKey() ? "'TODAY'" : "MMM d"
        return output.string(from: date).uppercased()
    }
    func tick() {
        let now = Date(); let elapsed = now.timeIntervalSince(lastTick); lastTick = now
        let oldDay = ledger.day; rollover()
        idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) >= 60
        if !paused && !sleeping && !idle && oldDay == ledger.day {
            if let page = knownPages[activeID], ledger.apps?[activeID] == nil { ledger.apps?[activeID] = page.usage }
            ledger.record(elapsed, mode: mode, appID: activeID, appName: knownPages[activeID]?.host ?? activeName)
            if browserID == "com.google.Chrome" && activeID.hasPrefix("site:") && mode == nil { chromeSessionSites.insert(activeID) }
            if elapsed > 0 && elapsed <= 3 && !activeID.isEmpty {
                activeSeconds += elapsed; telemetrySeconds += elapsed
            }
        }
        ticks += 1; if ticks % 10 == 0 { save() }
        if ticks % 900 == 0 { reportTelemetry() }
        if ticks % 3 == 0 && !sleeping && !paused {
            checkBrowser()
            for id in expandedBrowsers where id != browserID { checkBrowser(id) }
        }
        render()
    }
    @objc func activated(_ n: Notification) {
        guard let next = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              next.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        tick()
        updateApp(next)
        render(); checkBrowser()
    }
    func updateApp(_ app: NSRunningApplication?) {
        guard let app = app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        activeSeconds = 0; browserGeneration += 1
        activeID = app.bundleIdentifier ?? "process:\(app.localizedName ?? "unknown")"
        activeName = app.localizedName ?? "Unknown app"
        browserID = browsers.contains(activeID) ? activeID : nil
        browserName = activeName
        if ledger.apps == nil { ledger.apps = [:] }
        if browserID != nil, ledger.apps?[activeID] == nil { ledger.apps?[activeID] = AppUsage(name: activeName) }
        mode = effectiveMode(activeID); switched = Date(); lastTick = Date()
    }
    func siteMode(_ host: String) -> String? {
        if consumeSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return "consume" }
        if createSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return "create" }
        return nil
    }
    func checkBrowser(_ requestedID: String? = nil) {
        guard let id = requestedID ?? browserID, browsers.contains(id), !checkingBrowsers.contains(id) else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
            browserSnapshots[id] = BrowserSnapshot(pages: [])
            return
        }
        checkingBrowsers.insert(id)
        let name = app.localizedName ?? ledger.apps?[id]?.name ?? id
        let generation = browserGeneration
        browserQueue.async { [weak self] in
            let snapshot = BrowserSnapshot.read(id: id, name: name)
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Keep the in-flight guard while settling time; tick can request another poll.
                defer { self.checkingBrowsers.remove(id) }
                self.browserSnapshots[id] = snapshot
                if self.ledger.apps == nil { self.ledger.apps = [:] }
                if self.ledger.apps?[id] == nil { self.ledger.apps?[id] = AppUsage(name: name) }
                for page in snapshot.pages {
                    self.knownPages[page.id] = page
                    if self.ledger.apps?[page.id] == nil { self.ledger.apps?[page.id] = page.usage }
                }
                // Discard active-context results from a browser switched away from and back to.
                if self.browserID == id && self.browserGeneration == generation {
                    let page = snapshot.active
                    let key = page?.id ?? id
                    if key != self.activeID {
                        self.tick()
                        self.activeSeconds = 0; self.activeID = key
                        self.activeName = page?.host ?? name
                        self.mode = self.effectiveMode(key)
                        self.switched = Date(); self.lastTick = Date()
                    }
                }
                self.render()
            }
        }
    }
    @objc func sleepNow() { tick(); sleeping = true; save(); render() }
    @objc func wakeNow() { sleeping = false; lastTick = Date(); updateApp(NSWorkspace.shared.frontmostApplication); render() }
    @objc func chooseConsume() { choose("consume") }
    @objc func chooseCreate() { choose("create") }
    func choose(_ value: String) {
        guard !activeID.isEmpty else { return }
        tick(); setClassification(activeID, value: value); save(); render()
    }
    @objc func resetAll() {
        if let snapshot = resetUndo {
            resetUndoTimer?.invalidate(); resetUndoTimer = nil
            ledger = snapshot.ledger; rules = snapshot.rules; activeSeconds = snapshot.activeSeconds
            paused = snapshot.paused; prompted = snapshot.prompted; chromeSessionSites = snapshot.chromeSessionSites
            mode = snapshot.mode; resetUndo = nil; lastTick = Date(); save(); render(); return
        }
        tick()
        resetUndo = ResetSnapshot(ledger: ledger, rules: rules, activeSeconds: activeSeconds, paused: paused, prompted: prompted, chromeSessionSites: chromeSessionSites, mode: mode)
        resetUndoTimer?.invalidate()
        resetUndoTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            self?.resetUndo = nil; self?.panel.forget.title = "RESET"; self?.panel.forget.needsDisplay = true
        }
        ledger = Ledger(day: dayKey())
        rules = [:]; activeSeconds = 0; paused = false
        prompted.removeAll(); chromeSessionSites.removeAll()
        panel.reviewingPending = false
        mode = effectiveMode(activeID)
        lastTick = Date(); save(); render()
    }
    @objc func forgetApp() { tick(); setClassification(activeID, value: nil); prompted.insert(activeID); save(); render() }
    @objc func togglePause() { tick(); paused.toggle(); lastTick = Date(); save(); render() }
    @objc func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            item.target = self; menu.addItem(item)
            let account = NSMenuItem(title: UpdateCredential.load() == nil ? "Sign In for Updates…" : "Update Account…", action: #selector(updateAccount), keyEquivalent: "")
            account.target = self; menu.addItem(account)
            let telemetry = NSMenuItem(title: "Share Anonymous Total", action: #selector(toggleTelemetry), keyEquivalent: "")
            telemetry.target = self; telemetry.state = telemetryEnabled ? .on : .off; menu.addItem(telemetry)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit Ratio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp; menu.addItem(quit)
            if let button = status.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
        } else { togglePopover() }
    }
    @objc func checkForUpdates() {
        save()
        guard UpdateCredential.load() != nil else { showUpdateSignIn(); return }
        updaterController.checkForUpdates(nil)
    }
    @objc func updateAccount() { showUpdateSignIn() }
    @objc func toggleTelemetry() {
        telemetryEnabled.toggle(); defaults.set(telemetryEnabled, forKey: "anonymousTotalsEnabled")
        if telemetryEnabled { reportTelemetry() }
    }
    func reportTelemetry() {
        guard telemetryEnabled, !telemetryInstallID.isEmpty,
              Date().timeIntervalSince(lastTelemetryReport) >= 60,
              let credential = UpdateCredential.load() else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let body: [String: Any] = ["install": telemetryInstallID, "totalSeconds": Int(telemetrySeconds), "version": version]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "https://visualizevalue.com/api/ratio/telemetry") else { return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization"); request.httpBody = data
        lastTelemetryReport = Date()
        URLSession.shared.dataTask(with: request).resume()
    }
    func enableAutomaticUpdates() {
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = true
    }
    func showUpdateSignIn() {
        showPopover()
        if signInView == nil {
            let view = UpdateSignInView(frame: panel.bounds)
            view.onClose = { [weak self] in self?.signInView?.removeFromSuperview(); self?.signInView = nil }
            view.onVerified = { [weak self] credential in
                guard let self = self else { return }
                self.updaterController.updater.httpHeaders = ["Authorization": "Bearer " + credential.token]
                if !self.updaterStarted {
                    do { try self.updaterController.updater.start(); self.updaterStarted = true } catch { return }
                }
                self.enableAutomaticUpdates()
                self.signInView?.removeFromSuperview(); self.signInView = nil
                self.popover.performClose(nil)
                self.updaterController.checkForUpdates(nil)
            }
            panel.addSubview(view, positioned: .above, relativeTo: nil); signInView = view
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.window?.makeKey(); panel.window?.makeFirstResponder(signInView?.input)
    }
    @objc func togglePopover() { if popover.isShown { popover.performClose(nil) } else { showPopover() } }
    func showPopover() {
        guard let button = status.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    func render() {
        panel.selectedTab = 0
        let total = ledger.consume + ledger.create
        let c = total > 0 ? Int((ledger.create / total * 100).rounded()) : 0
        let ratioText = total > 0 ? "\(c) / \(100 - c)" : "— / —"
        let styledRatio = NSMutableAttributedString(string: ratioText, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 48, weight: .regular), .foregroundColor: panelText])
        if let slash = ratioText.range(of: "/ ") {
            let range = NSRange(slash.upperBound..<ratioText.endIndex, in: ratioText)
            styledRatio.addAttribute(.foregroundColor, value: NSColor.darkGray, range: range)
        }
        let alignment = NSMutableParagraphStyle(); alignment.alignment = .center
        styledRatio.addAttribute(.paragraphStyle, value: alignment, range: NSRange(location: 0, length: styledRatio.length))
        panel.totals.attributedStringValue = styledRatio
        let state = paused ? "PAUSED" : sleeping || idle ? "AWAY" : mode == "create" ? "CREATING" : mode == "consume" ? "CONSUMING" : "UNCLASSIFIED"
        panel.title.stringValue = "CREATE:CONSUME"
        let tracking = !paused && !sleeping && !idle
        let liveStatus = tracking ? "TRACKING" : state
        panel.context.stringValue = liveStatus
        panel.trackedTotal.stringValue = duration((ledger.apps ?? [:]).values.reduce(0) { $0 + $1.seconds })
        panel.note.stringValue = paused ? "Tracking paused. Click Resume to count." : sleeping || idle ? "Away · counting resumes with activity." : mode == nil ? "App time is counting. Choose a mode to include it in your ratio." : state + " · time updates every second.\nClick a mode to correct it."
        panel.pause.title = paused ? "▶" : "Ⅱ"
        panel.forget.title = resetUndo == nil ? "RESET" : "UNDO"
        panel.pause.setAccessibilityLabel(paused ? "Resume tracking" : "Pause tracking")
        panel.pause.toolTip = paused ? "Resume tracking" : "Pause tracking"
        panel.consume.state = mode == "consume" ? .on : .off; panel.create.state = mode == "create" ? .on : .off
        let symbol = paused || idle || sleeping ? "Ⅱ" : mode == "create" ? "↑" : mode == "consume" ? "↓" : "?"
        let statusTitle = total > 0 ? "\(symbol) \(c)/\(100-c)" : "\(symbol) Ratio"
        let statusColor: NSColor = !tracking ? .labelColor : mode == nil ? unclassifiedColor : mode == "create" ? createColor : consumeColor
        status.button?.attributedTitle = NSAttributedString(string: statusTitle, attributes: [.font: interfaceFont, .foregroundColor: statusColor])
        status.button?.toolTip = "Ratio · \(state.lowercased()) · \(activeName)"
        if panel.showingApps {
            let appTotal = (ledger.apps ?? [:]).values.reduce(0) { $0 + $1.seconds }
            panel.title.stringValue = (tracking ? "TRACKING · " : state + " · ") + duration(appTotal) + " TODAY"
            panel.note.stringValue = "App + website time. Includes unclassified use. Pauses after 60s idle."
        }
        if panel.selectedTab == 2 {
            panel.title.stringValue = "CATEGORIZE / ACTIVITY"
            panel.note.stringValue = "Applies to today's uncategorized time.\nUse Ratio or Apps to review later."
        }
        if panel.reviewingPending { panel.context.stringValue = "TO CATEGORIZE" }
        panel.refreshApps()
        panel.needsDisplay = true
    }
    func applicationWillTerminate(_ notification: Notification) { save(); reportTelemetry() }
}

if CommandLine.arguments.contains("--browser-test") {
    _ = NSApplication.shared
    let snapshot = BrowserSnapshot.read(id: "company.thebrowser.dia", name: "Dia")
    if let error = snapshot.error { print("Browser read failed: " + error); exit(1) }
    print("PASS: Dia snapshot contains \(snapshot.pages.count) unique web pages; active web page: \(snapshot.active != nil)")
} else if CommandLine.arguments.contains("--preview") {
    _ = NSApplication.shared
    let suite = "com.visualizevalue.ratio.preview." + UUID().uuidString
    let previewDefaults = UserDefaults(suiteName: suite)!
    defer { previewDefaults.removePersistentDomain(forName: suite) }
    let owner = AppDelegate(defaults: previewDefaults)
    owner.ledger = Ledger(day: dayKey(), consume: 3600, create: 1200)
    owner.history = [DaySummary(day: "2026-09-14", create: 61, consume: 39), DaySummary(day: "2026-09-13", create: 74, consume: 26), DaySummary(day: "2026-09-12", create: 48, consume: 52)]
    let dia = "company.thebrowser.dia"
    let pages = [
        BrowserPage(url: "https://example.com/brief", title: "Project brief", browserID: dia, browserName: "Dia")!,
        BrowserPage(url: "https://example.com/reading", title: "Reading list", browserID: dia, browserName: "Dia")!,
        BrowserPage(url: "https://figma.com/file/demo", title: "Design workspace", browserID: dia, browserName: "Dia")!
    ]
    owner.ledger = Ledger(day: dayKey())
    owner.ledger.apps = [dia: AppUsage(name: "Dia", lastUsed: 100), "editor": AppUsage(name: "Xcode", lastUsed: 10)]
    owner.rules = [dia: "create", pages[1].id: "consume"]
    owner.browserSnapshots[dia] = BrowserSnapshot(pages: pages, active: pages[0])
    for (index, page) in pages.enumerated() {
        owner.knownPages[page.id] = page; owner.ledger.apps?[page.id] = page.usage
        for _ in 0..<(index == 0 ? 420 : index == 1 ? 80 : 120) {
            owner.ledger.record(3, mode: owner.effectiveMode(page.id), appID: page.id, appName: page.host)
        }
    }
    owner.activeName = pages[0].host; owner.activeID = pages[0].id; owner.mode = "create"
    owner.status = NSStatusBar.system.statusItem(withLength: 0)
    let view = RatioView(frame: NSRect(x: 0, y: 0, width: 360, height: 352))
    owner.panel = view; view.owner = owner
    let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    // Exercise the real controls without touching the user's tracking data or browser.
    owner.paused = true; owner.checkingBrowsers.insert(dia)
    owner.render()
    let disclosure = view.reviewList.subviews.compactMap { $0 as? ReviewButton }.first { $0.siteID == dia && $0.mode.isEmpty }!
    disclosure.performClick(nil)
    precondition(owner.expandedBrowsers.contains(dia))
    let consumePage = view.reviewList.subviews.compactMap { $0 as? ReviewButton }.first { $0.siteID == pages[0].id && $0.mode == "consume" }!
    consumePage.performClick(nil)
    precondition(owner.rules[pages[0].id] == "consume")
    let restorePage = view.reviewList.subviews.compactMap { $0 as? ReviewButton }.first { $0.siteID == pages[0].id && $0.mode.isEmpty }!
    restorePage.performClick(nil)
    precondition(owner.rules[pages[0].id] == nil && owner.effectiveMode(pages[0].id) == "create")
    owner.paused = false
    print("PASS: native disclosure, page classification, and restore-default controls")
    for variant in ["collapsed", "expanded", "light", "history"] {
        lightMode = variant == "light"
        owner.expandedBrowsers = variant == "collapsed" ? [] : [dia]
        view.showingHistory = variant == "history"
        view.applyTheme(); owner.render(); view.display()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments.last! + "/ratio-" + variant + ".png"))
    }
} else if CommandLine.arguments.contains("--self-test") {
    let classifier = AppDelegate()
    precondition(classifier.siteMode("x.com") == "consume")
    precondition(classifier.siteMode("www.youtube.com") == "consume")
    precondition(classifier.siteMode("docs.google.com") == "create")
    precondition(classifier.siteMode("notx.com") == nil)
    precondition(classifier.siteMode("x.com.example.org") == nil)
    print("PASS: website classification and hostname boundaries")
    let dia = "company.thebrowser.dia"
    let pageA = BrowserPage(url: "https://example.com/work?doc=1", title: "Project brief", browserID: dia, browserName: "Dia")!
    let pageB = BrowserPage(url: "https://example.com/work?doc=2", title: "Reading list", browserID: dia, browserName: "Dia")!
    let samePage = BrowserPage(url: "https://example.com/work?doc=1#section", title: "Changed title", browserID: dia, browserName: "Dia")!
    let otherBrowser = BrowserPage(url: "https://example.com/work?doc=1", title: "Project brief", browserID: "com.apple.Safari", browserName: "Safari")!
    precondition(pageA.id != pageB.id && pageA.id == samePage.id && pageA.id != otherBrowser.id)
    precondition(BrowserPage(url: "dia://newtab", title: "New tab", browserID: dia, browserName: "Dia") == nil)
    precondition(!pageA.id.contains("doc=1") && pageA.usage.name == "example.com")
    print("PASS: distinct pages, browser isolation, fragment normalization, URL privacy")
    classifier.ledger = Ledger(day: "test")
    classifier.ledger.apps = [dia: AppUsage(name: "Dia"), pageA.id: pageA.usage, pageB.id: pageB.usage]
    classifier.knownPages = [pageA.id: pageA, pageB.id: pageB]
    classifier.browserSnapshots[dia] = BrowserSnapshot(pages: [pageA, pageB], active: pageA)
    classifier.activeID = pageA.id
    classifier.setClassification(dia, value: "create")
    precondition(classifier.effectiveMode(pageA.id) == "create" && classifier.effectiveMode(pageB.id) == "create")
    classifier.ledger.record(3, mode: classifier.effectiveMode(pageA.id), appID: pageA.id, appName: pageA.host)
    classifier.ledger.record(2, mode: classifier.effectiveMode(pageB.id), appID: pageB.id, appName: pageB.host)
    classifier.setClassification(pageB.id, value: "consume")
    precondition(classifier.ledger.create == 3 && classifier.ledger.consume == 2)
    classifier.setClassification(dia, value: "consume")
    precondition(classifier.ledger.create == 0 && classifier.ledger.consume == 5)
    classifier.setClassification(dia, value: "create")
    precondition(classifier.effectiveMode(pageB.id) == "consume" && classifier.ledger.create == 3 && classifier.ledger.consume == 2)
    precondition(classifier.mode == "create")
    classifier.setClassification(pageB.id, value: nil)
    precondition(classifier.rules[pageB.id] == nil && classifier.ledger.create == 5 && classifier.ledger.consume == 0)
    classifier.setClassification(dia, value: "create")
    precondition(classifier.ledger.create == 5, "Reclassifying a browser must be idempotent")
    print("PASS: browser inheritance, page overrides, reset, parent changes, exact accounting")
    let collapsed = classifier.activityRows(pendingOnly: false)
    precondition(collapsed.count == 1 && collapsed[0].seconds == 5 && collapsed[0].active)
    classifier.expandedBrowsers.insert(dia)
    let expanded = classifier.activityRows(pendingOnly: false)
    precondition(expanded.count == 3 && expanded[1].name == "Project brief" && expanded[2].seconds == 2)
    precondition(classifier.ledger.apps?[dia]?.seconds == 0, "Browser rollups must not duplicate page time")
    classifier.setClassification(dia, value: nil)
    precondition(classifier.ledger.create == 0 && classifier.ledger.consume == 0 && classifier.pendingSites.count == 2)
    classifier.expandedBrowsers.removeAll()
    precondition(classifier.activityRows(pendingOnly: true).count == 3, "Pending children must remain accessible when collapsed")
    classifier.setClassification(dia, value: "consume")
    precondition(classifier.pendingSites.isEmpty && classifier.ledger.consume == 5)
    print("PASS: collapsed rollups, expanded rows, pending review, unknown inheritance")
    classifier.setClassification(pageA.id, value: "create")
    let savedLedger = try! JSONEncoder().encode(classifier.ledger)
    let savedRules = try! JSONEncoder().encode(classifier.rules)
    let reloaded = AppDelegate()
    reloaded.ledger = try! JSONDecoder().decode(Ledger.self, from: savedLedger)
    reloaded.rules = try! JSONDecoder().decode([String: String].self, from: savedRules)
    precondition(reloaded.effectiveMode(pageA.id) == "create" && reloaded.effectiveMode(pageB.id) == "consume")
    let stored = String(data: savedLedger, encoding: .utf8)!
    precondition(!stored.contains("Project brief") && !stored.contains("doc=1"))
    let fresh = BrowserPage(url: "https://example.org", title: "Unvisited", browserID: dia, browserName: "Dia")!
    classifier.ledger.apps?[fresh.id] = fresh.usage
    classifier.browserSnapshots[dia] = BrowserSnapshot(pages: [fresh])
    classifier.expandedBrowsers.insert(dia)
    precondition(classifier.effectiveMode(fresh.id) == "consume")
    precondition(classifier.activityRows(pendingOnly: false).first?.seconds == 5)
    classifier.browserSnapshots[dia] = BrowserSnapshot(pages: [])
    precondition(!classifier.activityRows(pendingOnly: false).contains { $0.id == fresh.id }, "Closed, unvisited pages must disappear")
    print("PASS: persistence, private labels, new pages, closed pages, zero-time tabs")

    var l = Ledger(day: "test")
    l.record(2, mode: "create"); l.record(1, mode: "consume"); l.record(2, mode: nil)
    l.record(100, mode: "create"); l.record(-1, mode: "consume")
    precondition(l.create == 2 && l.consume == 1, "Accounting must exclude gaps and unknown time")
    let data = try! JSONEncoder().encode(l)
    let restored = try! JSONDecoder().decode(Ledger.self, from: data)
    precondition(restored.create == 2 && restored.day == "test")
    let legacy = try! JSONDecoder().decode(Ledger.self, from: Data("{\"day\":\"test\",\"consume\":7,\"create\":9}".utf8))
    precondition(legacy.consume == 7 && legacy.create == 9 && legacy.apps == nil)
    var usage = legacy
    usage.record(2, mode: nil, appID: "browser", appName: "Browser")
    usage.record(1, mode: "create", appID: "editor", appName: "Editor")
    usage.record(100, mode: "create", appID: "editor", appName: "Editor")
    precondition(usage.apps?["browser"]?.seconds == 2 && usage.apps?["editor"]?.seconds == 1)
    precondition(usage.consume == 7 && usage.create == 10)
    let usageSaved = try! JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(usage))
    precondition(usageSaved.apps?["browser"]?.name == "Browser")
    precondition(Ledger(day: "tomorrow").apps?.isEmpty == true)
    usage.classifyPending("browser", mode: "consume")
    precondition(usage.consume == 9 && usage.apps?["browser"]?.unclassified == 0)
    usage.classifyPending("browser", mode: "consume")
    precondition(usage.consume == 9, "Review must not double count")
    print("PASS: retrospective categorization and duplicate review protection")
    print("PASS: app attribution, legacy migration, daily reset, app persistence")
    var reclassified = Ledger(day: "test")
    reclassified.record(3, mode: "create", appID: "editor", appName: "Editor")
    reclassified.record(2, mode: "consume", appID: "social", appName: "Social")
    reclassified.classifyPending("social", mode: "create")
    precondition(reclassified.create == 5 && reclassified.consume == 0)
    reclassified.classifyPending("editor", mode: "consume")
    reclassified.classifyPending("social", mode: "consume")
    precondition(reclassified.create == 0 && reclassified.consume == 5)
    reclassified.classifyPending("social", mode: "consume")
    precondition(reclassified.consume == 5)
    reclassified.classifyPending("social", mode: "neutral")
    precondition(reclassified.create == 0 && reclassified.consume == 3)
    reclassified.record(2, mode: "neutral", appID: "social", appName: "Social")
    precondition(reclassified.create == 0 && reclassified.consume == 3 && reclassified.apps?["social"]?.seconds == 4)
    reclassified.classifyPending("social", mode: "consume")
    precondition(reclassified.consume == 7)
    let roundtrip = try! JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(reclassified))
    precondition(roundtrip.apps?["social"]?.consumeSeconds == 4)
    print("PASS: recategorization moves all app time, neutral exclusion, idempotency and persistence")
    print("PASS: classified time, unknown exclusion, suspension gaps, persistence")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate
    app.setActivationPolicy(.accessory); app.run()
}
