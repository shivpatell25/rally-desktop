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

    private var pageCount: Int { max(1, (items.count + pageSize - 1) / pageSize) }
    private var safePage: Int { min(max(0, page), pageCount - 1) }
    private var visible: [Item] { Array(items.dropFirst(safePage * pageSize).prefix(pageSize)) }
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
                ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                    content(item, cardSize, focus)
                }
                // Keep row width stable on a short last page.
                if visible.count < pageSize {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        page = next
        let ids = Array(items.dropFirst(next * pageSize).prefix(pageSize)).map(idFor)
        focus.wrappedValue = delta > 0 ? ids.first : ids.last
    }

    private func step(_ delta: Int) {
        guard let cur = focus.wrappedValue else {
            focus.wrappedValue = visible.map(idFor).first
            return
        }
        let ids = visible.map(idFor)
        guard let col = ids.firstIndex(of: cur) else { return }
        let next = col + delta
        if next < 0 || next >= ids.count {
            turn(delta)
        } else {
            focus.wrappedValue = ids[next]
        }
    }
}
