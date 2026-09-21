import RallyCore
import SwiftUI

/// TV paged row: exactly `pageSize` cards fill the viewport; paging replaces
/// the whole page (mirrors RallyPagedRow). Arrow keys turn pages at the edges.
struct PagedShelf<Item, Content: View>: View {
    @Environment(\.tvMetrics) private var m

    var title: String?
    var items: [Item]
    var pageSize: Int
    var aspect: CGFloat
    var idFor: (Item) -> String
    var focus: FocusState<String?>.Binding
    @Binding var page: Int
    @ViewBuilder var content: (Item, CGSize, FocusState<String?>.Binding) -> Content
    @State private var lastDelta = 1

    private var pageCount: Int { max(1, (items.count + pageSize - 1) / pageSize) }
    private var safePage: Int { min(max(0, page), pageCount - 1) }
    private var visibleIds: [String] { Array(items.dropFirst(safePage * pageSize).prefix(pageSize)).map(idFor) }
    private func item(for id: String) -> Item? { items.first(where: { idFor($0) == id }) }
    private var cardSize: CGSize {
        let viewport = m.width - m.hPad * 2
        let w = (viewport - m.cardSpacing * CGFloat(pageSize - 1)) / CGFloat(pageSize)
        return CGSize(width: w, height: w / aspect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 15, weight: .bold)).tracking(2.4)
                        .foregroundStyle(RallyTheme.textPrimary)
                    Spacer()
                    if pageCount > 1 {
                        HStack(spacing: 8) {
                            Button("‹") { turn(-1) }.buttonStyle(.plain)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(safePage > 0 ? RallyTheme.textPrimary : RallyTheme.textTertiary)
                                .disabled(safePage == 0)
                            Text("\(safePage + 1)/\(pageCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(RallyTheme.textSecondary)
                            Button("›") { turn(1) }.buttonStyle(.plain)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(safePage < pageCount - 1 ? RallyTheme.textPrimary : RallyTheme.textTertiary)
                                .disabled(safePage == pageCount - 1)
                        }
                    }
                }
            }
            HStack(spacing: m.cardSpacing) {
                ForEach(visibleIds, id: \.self) { id in
                    if let item = item(for: id) {
                        content(item, cardSize, focus)
                            .transition(.asymmetric(
                                insertion: .move(edge: lastDelta >= 0 ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: lastDelta >= 0 ? .leading : .trailing).combined(with: .opacity)))
                    }
                }
                // Keep row width stable on a short last page.
                if visibleIds.count < pageSize {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: page)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
                if drag.translation.width < -60 {
                    turn(1)
                } else if drag.translation.width > 60 {
                    turn(-1)
                }
            })
        }
        .onMoveCommand { dir in
            switch dir {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .onChange(of: items.count) { _ in
            if page > pageCount - 1 { page = pageCount - 1 }
        }
    }

    private func turn(_ delta: Int) {
        let next = min(max(0, safePage + delta), pageCount - 1)
        guard next != safePage else { return }
        lastDelta = delta
        page = next
        let ids = Array(items.dropFirst(next * pageSize).prefix(pageSize)).map(idFor)
        focus.wrappedValue = delta > 0 ? ids.first : ids.last
    }

    private func step(_ delta: Int) {
        guard let cur = focus.wrappedValue else {
            focus.wrappedValue = visibleIds.first
            return
        }
        let ids = visibleIds
        guard let col = ids.firstIndex(of: cur) else { return }
        let next = col + delta
        if next < 0 || next >= ids.count {
            turn(delta)
        } else {
            focus.wrappedValue = ids[next]
        }
    }
}
