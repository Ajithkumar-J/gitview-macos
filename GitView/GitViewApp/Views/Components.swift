import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(Shared)
import Shared
#endif

// MARK: - Status colors

extension GitChangeKind {
    var color: Color {
        switch self {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .typeChanged: .purple
        case .untracked: .teal
        case .conflicted: .pink
        }
    }
}

/// Single-letter status badge, e.g. **M** in orange.
struct ChangeKindBadge: View {
    let kind: GitChangeKind

    var body: some View {
        Text(kind.letter)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(kind.color)
            .frame(width: 16, height: 16)
            .background(kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(kind.title)
    }
}

/// System icon for a file type, without touching the file on disk.
struct FileTypeIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: Self.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
    }

    private static func icon(for path: String) -> NSImage {
        let fileExtension = (path as NSString).pathExtension
        let type = UTType(filenameExtension: fileExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// File name in primary color followed by its folder in secondary color.
struct FilePathLabel: View {
    let path: String
    var originalPath: String?

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(DisplayText.visible(name, keepNewlines: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !directory.isEmpty {
                    Text(DisplayText.visible(directory, keepNewlines: false))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if let originalPath {
                Text("from \(originalPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(originalPath.map { "\($0) → \(path)" } ?? path)
    }
}

/// Small ↑2 ↓3 indicator.
struct AheadBehindView: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: 6) {
            if ahead > 0 {
                Label("\(ahead)", systemImage: "arrow.up")
                    .help("\(ahead) commit\(ahead == 1 ? "" : "s") to push")
            }
            if behind > 0 {
                Label("\(behind)", systemImage: "arrow.down")
                    .help("\(behind) commit\(behind == 1 ? "" : "s") to pull")
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A Git decoration (branch, remote branch, tag) shown as a capsule.
struct RefChip: View {
    let ref: String

    private var kind: (text: String, icon: String, color: Color) {
        if ref.hasPrefix("HEAD -> ") {
            return (String(ref.dropFirst(8)), "checkmark.circle.fill", .green)
        }
        if ref.hasPrefix("tag: ") {
            return (String(ref.dropFirst(5)), "tag.fill", .orange)
        }
        if ref == "HEAD" {
            return ("HEAD", "smallcircle.filled.circle", .green)
        }
        if ref.contains("/") {
            return (ref, "cloud.fill", .blue)
        }
        return (ref, "arrow.triangle.branch", .purple)
    }

    var body: some View {
        let kind = kind
        Label(kind.text, systemImage: kind.icon)
            .labelStyle(CompactLabelStyle())
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(kind.color)
            .background(kind.color.opacity(0.12), in: Capsule())
    }
}

/// Inline search field used at the top of list columns.
struct FilterField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Section header with a title, a count and trailing actions.
struct ListSectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            actions
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
        }
    }
}

// MARK: - Dates

enum GitDateFormatter {
    /// "Today 10:32", "Yesterday", "Monday", "Aug 30", "Aug 30, 2024"
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today " + date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7, days >= 0 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func long(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }
}
