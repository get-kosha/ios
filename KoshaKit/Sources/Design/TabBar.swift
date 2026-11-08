import SwiftUI

/// A tab: its label and Phosphor icon (regular when idle, fill in the selection colour when picked).
public struct Tab<T: Hashable>: Identifiable {
    public let value: T
    public let label: String
    public let icon: String
    public var id: T { value }

    public init(_ value: T, label: String, icon: String) {
        self.value = value
        self.label = label
        self.icon = icon
    }
}

/// The tab bar: four tabs around the raised Add button (56×52, radius 18, ink). Glass ground with a hairline on top and
/// a 12pt blur, over the home indicator.
public struct TabBar<T: Hashable>: View {
    let tabs: [Tab<T>]
    @Binding var selected: T
    let addLabel: String
    let onAdd: () -> Void
    @Environment(\.kosha) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var bottomInset: CGFloat = 0

    public init(_ tabs: [Tab<T>], selected: Binding<T>, addLabel: String, onAdd: @escaping () -> Void) {
        self.tabs = tabs
        _selected = selected
        self.addLabel = addLabel
        self.onAdd = onAdd
    }

    public var body: some View {
        let c = theme.colors
        let half = tabs.count / 2
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                if i == half { addButton }
                let on = tab.value == selected
                Button { selected = tab.value } label: {
                    VStack(spacing: 3) {
                        PhIcon(tab.icon, size: 24, fill: on, color: on ? c.selection : c.ink3)
                        Text(tab.label)
                            .font(.custom(on ? "Geist-Medium" : "Geist-Regular", size: 11, relativeTo: .caption2))
                            .foregroundStyle(on ? c.ink : c.ink3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                // At the accessibility sizes, touch and hold shows the tab's name large, as the system tab bar does.
                .accessibilityShowsLargeContentViewer { PhIcon(tab.icon, size: 24, fill: on); Text(tab.label) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 30 - bottomInset)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { bottomInset = proxy.safeAreaInsets.bottom }
                .onChange(of: proxy.safeAreaInsets.bottom) { _, inset in bottomInset = inset }
        })
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                c.glass
                c.line.frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .sensoryFeedback(.selection, trigger: selected)
        // The bar keeps its size from extra large up, like the system's; the large content viewer reads it larger.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private var addButton: some View {
        let c = theme.colors
        return Button(action: onAdd) {
            PhIcon("plus", size: 26, color: c.onInk)
                .frame(width: 56, height: 52)
                .background(c.ink, in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(addLabel)
    }
}
