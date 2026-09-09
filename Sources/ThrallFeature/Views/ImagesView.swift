import SwiftUI
import AinkradAppKit

/// Task O — Images.
///
/// **Sorted by size, descending, on the first click**, because that is the
/// only question anyone opens this area to answer: what is taking the space.
/// 13 of the 30 images on the reference machine are unused and account for
/// 3.5 GB.
struct ImagesView: View {
    @ObservedObject var model: ThrallViewModel
    @ObservedObject var storage: ThrallStorageModel

    @Environment(\.ainkradTheme) private var theme
    /// Pre-set to size-descending rather than left nil, so the table opens on
    /// the answer instead of on insertion order.
    @State private var sort: AinkradTableSort? = AinkradTableSort(columnID: "size",
                                                                  ascending: false)

    private struct Row: Identifiable {
        let id: String
        let tag: String
        let size: Int64
        let containers: Int
        let created: Int
        let isDangling: Bool
    }

    private var rows: [Row] {
        let mapped = storage.images.map { image in
            Row(id: image.id,
                tag: image.repoTags.first ?? "<none>:<none>",
                size: image.size,
                containers: image.containers,
                created: image.created,
                isDangling: image.isDangling)
        }
        guard let sort else { return mapped.sorted { $0.size > $1.size } }
        let ordered: [Row]
        switch sort.columnID {
        case "tag": ordered = mapped.sorted { $0.tag < $1.tag }
        case "used": ordered = mapped.sorted { $0.containers < $1.containers }
        case "created": ordered = mapped.sorted { $0.created < $1.created }
        default: ordered = mapped.sorted { $0.size < $1.size }
        }
        return sort.ascending ? ordered : ordered.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = storage.error {
                AinkradEmptyState(icon: "exclamationmark.triangle",
                                  title: "Could not read images", message: error)
            } else if storage.isLoading && storage.usage == nil {
                AinkradLoadingState(label: "Reading image sizes… (system/df is slow)")
            } else if rows.isEmpty {
                AinkradEmptyState(icon: "archivebox", title: "No images",
                                  message: "Nothing is stored on \(model.engineLabel).")
            } else {
                ScrollView {
                    AinkradDataTable(rows: rows, columns: columns, sort: $sort)
                        .padding(.horizontal, AinkradSpacing.lg)
                        .padding(.bottom, AinkradSpacing.lg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await storage.load(client: model.engineClient) }
    }

    private var columns: [AinkradTableColumn<Row>] {
        [
            AinkradTableColumn(id: "tag", title: "Image") { $0.tag },
            AinkradTableColumn(id: "size", title: "Size", alignment: .trailing) {
                ThrallReclaimPlan.humanBytes($0.size)
            },
            AinkradTableColumn(id: "used", title: "Containers", alignment: .trailing) {
                // Zero is the reclaim signal, so it is spelled out rather than
                // left as a bare 0 among other numbers.
                $0.containers == 0 ? "0 — unused" : "\($0.containers)"
            },
            AinkradTableColumn(id: "created", title: "Created", alignment: .trailing) {
                Date(timeIntervalSince1970: TimeInterval($0.created))
                    .formatted(date: .abbreviated, time: .omitted)
            },
        ]
    }

    private var header: some View {
        HStack(spacing: AinkradSpacing.md) {
            Text("\(rows.count) images")
                .font(.system(size: 11, weight: .medium))
            let unused = rows.filter { $0.containers == 0 }
            if !unused.isEmpty {
                AinkradBadge(text: "\(unused.count) unused · "
                             + ThrallReclaimPlan.humanBytes(unused.reduce(0) { $0 + $1.size }),
                             status: .warning)
            }
            Spacer(minLength: 0)
            if let loadedAt = storage.loadedAt {
                Text("read \(loadedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(theme.foreground.opacity(0.4))
            }
            AinkradIconButton(systemName: "arrow.clockwise", size: 24, tooltip: "Reload") {
                Task { await storage.load(client: model.engineClient, force: true) }
            }
        }
        .padding(.horizontal, AinkradSpacing.lg)
        .padding(.vertical, AinkradSpacing.sm)
        .background(theme.surface.opacity(0.25))
    }
}
