import AppKit
import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// Header + diff body used by both the Changes and History detail columns.
struct DiffPane<Accessory: View>: View {
    let path: String?
    var originalPath: String?
    var subtitle: String?
    let state: DiffState
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            if let path {
                header(path: path)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(path: String) -> some View {
        HStack(spacing: 10) {
            FileTypeIcon(path: path)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.visible((path as NSString).lastPathComponent, keepNewlines: false))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DisplayText.visible(subtitleText(path: path), keepNewlines: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .textSelection(.enabled)

            Spacer(minLength: 12)

            if case .loaded(let diff) = state, !diff.isBinary {
                HStack(spacing: 6) {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                .font(.callout.monospacedDigit().weight(.medium))
            }

            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func subtitleText(path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let location = originalPath.map { "Renamed from \($0)" } ?? (directory.isEmpty ? "Repository root" : directory)
        return [subtitle, location].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .placeholder(let message):
            ContentUnavailableView(message, systemImage: "doc.text.magnifyingglass")
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .failed(let message):
            ContentUnavailableView {
                Label("Unable to Show Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    .textSelection(.enabled)
            }
        case .loaded(let diff):
            if diff.isBinary {
                ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("GitView does not show changes inside binary files."))
            } else {
                VStack(spacing: 0) {
                    DiffTextView(diff: diff)
                    if diff.isTruncated {
                        Divider()
                        Label("Diff truncated to the first \(GitDiffParser.defaultLineLimit.formatted()) lines. Open the file in VS Code to see everything.", systemImage: "scissors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            }
        }
    }
}

extension DiffPane where Accessory == EmptyView {
    init(path: String?, originalPath: String? = nil, subtitle: String? = nil, state: DiffState) {
        self.init(path: path, originalPath: originalPath, subtitle: subtitle, state: state) { EmptyView() }
    }
}

// MARK: - AppKit text view

/// Read-only, selectable, non-wrapping diff renderer. NSTextView keeps large
/// diffs fast and gives native selection, find (⌘F) and copy.
struct DiffTextView: NSViewRepresentable {
    let diff: GitDiff

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.renderedDiff != diff, let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.renderedDiff = diff
        textView.textStorage?.setAttributedString(DiffRenderer.attributedString(for: diff))
        textView.scrollToBeginningOfDocument(nil)
        scrollView.contentView.scroll(to: .zero)
    }

    final class Coordinator {
        var renderedDiff: GitDiff?
    }
}

private extension NSAttributedString.Key {
    static let diffLineBackground = NSAttributedString.Key("GitViewDiffLineBackground")
}

/// Paints full-width backgrounds for added/removed lines and hunk headers.
private final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage {
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
                let characterIndex = self.characterIndexForGlyph(at: glyphRange.location)
                guard characterIndex < storage.length,
                      let color = storage.attribute(.diffLineBackground, at: characterIndex, effectiveRange: nil) as? NSColor
                else {
                    return
                }

                var fill = rect.offsetBy(dx: origin.x, dy: origin.y)
                fill.origin.x = 0
                fill.size.width = 100_000
                color.setFill()
                fill.fill()
            }
        }

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

private enum DiffRenderer {
    static func attributedString(for diff: GitDiff) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5

        let maxLine = diff.lines.reduce(0) { max($0, $1.oldLineNumber ?? 0, $1.newLineNumber ?? 0) }
        let width = max(3, String(maxLine).count)

        let gutterAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph
        ]

        let result = NSMutableAttributedString()
        result.beginEditing()

        for line in diff.lines {
            var textAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            var marker = " "
            var background: NSColor?

            switch line.kind {
            case .addition:
                marker = "+"
                background = NSColor.systemGreen.withAlphaComponent(0.14)
            case .deletion:
                marker = "−"
                background = NSColor.systemRed.withAlphaComponent(0.13)
            case .hunkHeader:
                textAttributes[.foregroundColor] = NSColor.secondaryLabelColor
                textAttributes[.font] = boldFont
                background = NSColor.systemBlue.withAlphaComponent(0.08)
            case .meta, .noNewline:
                textAttributes[.foregroundColor] = NSColor.secondaryLabelColor
            case .context:
                break
            }

            let lineStart = result.length
            let gutter: String
            if line.kind == .hunkHeader || line.kind == .meta || line.kind == .noNewline {
                gutter = String(repeating: " ", count: width * 2 + 3)
            } else {
                gutter = pad(line.oldLineNumber, width) + " " + pad(line.newLineNumber, width) + " " + marker + " "
            }

            result.append(NSAttributedString(string: " " + gutter, attributes: gutterAttributes))
            result.append(NSAttributedString(string: DisplayText.visible(line.text.replacingOccurrences(of: "\t", with: "    "), keepNewlines: false) + "\n", attributes: textAttributes))

            if let background {
                result.addAttribute(.diffLineBackground, value: background, range: NSRange(location: lineStart, length: result.length - lineStart))
            }
        }

        result.endEditing()
        return result
    }

    private static func pad(_ number: Int?, _ width: Int) -> String {
        let text = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }
}
