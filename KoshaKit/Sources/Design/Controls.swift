import SwiftUI
import Model

/// A press that dims slightly, for Kosha's own buttons (no system highlight).
public struct PressStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}

/// A white card with a hairline: radius 16, padding 16 (14 compact). `tight` puts rows edge to edge.
public struct Card<Content: View>: View {
    let tight: Bool
    let content: Content
    @Environment(\.kosha) private var theme

    public init(tight: Bool = false, @ViewBuilder content: () -> Content) {
        self.tight = tight
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: tight ? 0 : 12) { content }
            .padding(tight ? 0 : theme.dims.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.surface, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.colors.line))
            .clipShape(.rect(cornerRadius: 16))
    }
}

public struct Hairline: View {
    @Environment(\.kosha) private var theme
    public init() {}
    public var body: some View { theme.colors.line.frame(height: 1) }
}

/// A list row: at least 52 high (48 compact), padding 10/16, gap 12. With an action it is a button.
public struct ListRow<Content: View>: View {
    let action: (() -> Void)?
    let selected: Bool
    let content: Content
    @Environment(\.kosha) private var theme

    public init(selected: Bool = false, action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.action = action
        self.selected = selected
        self.content = content()
    }

    public var body: some View {
        let row = HStack(spacing: 12) { content }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: theme.dims.row, alignment: .leading)
            .background(selected ? theme.colors.sel : .clear)
        if let action {
            Button(action: action) { row.contentShape(Rectangle()) }.buttonStyle(PressStyle())
        } else {
            row
        }
    }
}

/// A category or menu icon on a 36×36 soft tile.
public struct IconTile: View {
    let icon: String
    @Environment(\.kosha) private var theme
    public init(_ icon: String) { self.icon = icon }
    public var body: some View {
        PhIcon(icon, size: 18)
            .frame(width: 36, height: 36)
            .background(theme.colors.soft, in: .rect(cornerRadius: 10))
    }
}

/// An account's colour: an 8pt rounded square. Hidden in neutral mode.
public struct AccountDot: View {
    let color: Color
    let size: CGFloat
    @Environment(\.kosha) private var theme
    public init(_ color: Color, size: CGFloat = 8) {
        self.color = color
        self.size = size
    }
    public var body: some View {
        if theme.colors.accountColours {
            RoundedRectangle(cornerRadius: size * 3 / 8).fill(color).frame(width: size, height: size)
        }
    }
}

/// A round 44pt icon button. It always has a label for VoiceOver.
public struct IconButton: View {
    let icon: String
    let label: String
    let solid: Bool
    let color: Color?
    let action: () -> Void
    @Environment(\.kosha) private var theme

    public init(_ icon: String, label: String, solid: Bool = false, color: Color? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.solid = solid
        self.color = color
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            PhIcon(icon, size: 22, color: color ?? theme.colors.ink2)
                .frame(width: 44, height: 44)
                .background(solid ? theme.colors.surface : .clear, in: .circle)
                .overlay { if solid { Circle().strokeBorder(theme.colors.line) } }
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

public enum KButtonStyle: Sendable { case primary, secondary, soft, danger }

public enum KButtonSize: Sendable {
    case large, medium, small
    var height: CGFloat { switch self { case .large: 52; case .medium: 44; case .small: 36 } }
    var radius: CGFloat { switch self { case .large: 14; case .medium: 12; case .small: 8 } }
    var font: CGFloat { switch self { case .large: 16; case .medium: 15; case .small: 14 } }
}

/// Primary is ink with on-ink text; secondary is surface with a hairline; soft is soft; danger is bad text on a 10%
/// tint. Disabled is 40% opacity. Large and medium fill the width; small hugs its text.
public struct KButton: View {
    let title: String
    let style: KButtonStyle
    let size: KButtonSize
    let icon: String?
    let action: () -> Void
    @Environment(\.kosha) private var theme
    @Environment(\.isEnabled) private var enabled

    public init(
        _ title: String, style: KButtonStyle = .primary, size: KButtonSize = .large, icon: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.size = size
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        let c = theme.colors
        let (ground, ink): (Color, Color) = switch style {
        case .primary: (c.ink, c.onInk)
        case .secondary: (c.surface, c.ink)
        case .soft: (c.soft, c.ink)
        case .danger: (c.bad.opacity(0.1), c.bad)
        }
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { PhIcon(icon, size: 18, color: ink) }
                Text(title).kFont(.sans(size.font, .medium)).foregroundStyle(ink).lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, size == .small ? 14 : 20)
            .frame(maxWidth: size == .small ? nil : .infinity, minHeight: size.height)
            .background(ground, in: .rect(cornerRadius: size.radius))
            .overlay {
                if style == .secondary { RoundedRectangle(cornerRadius: size.radius).strokeBorder(c.line) }
            }
            .contentShape(.rect(cornerRadius: size.radius))
        }
        .buttonStyle(PressStyle())
        .opacity(enabled ? 1 : 0.4)
    }
}

/// A status pill: 22 high on soft, 12pt text.
public struct Pill: View {
    let text: String
    let color: Color?
    @Environment(\.kosha) private var theme
    public init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }
    public var body: some View {
        Text(text).kFont(.xs).foregroundStyle(color ?? theme.colors.ink2).lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(theme.colors.soft, in: .capsule)
    }
}

/// A chip: 40 high (32 small), pill shaped, with a hairline. `on` gives it an ink outline; `soft` a soft ground and
/// no line. `leading` holds an icon or an account dot.
public struct Chip<Leading: View>: View {
    let text: String
    let on: Bool
    let soft: Bool
    let small: Bool
    let action: (() -> Void)?
    let leading: Leading
    @Environment(\.kosha) private var theme

    public init(
        _ text: String, on: Bool = false, soft: Bool = false, small: Bool = false, action: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() }
    ) {
        self.text = text
        self.on = on
        self.soft = soft
        self.small = small
        self.action = action
        self.leading = leading()
    }

    public var body: some View {
        let c = theme.colors
        let chip = HStack(spacing: 8) {
            leading
            Text(text).kFont(small ? .small : .body).lineLimit(1)
        }
        .padding(.horizontal, small ? 12 : 14)
        .frame(minHeight: small ? 32 : 40)
        .background(soft ? c.soft : c.surface, in: .capsule)
        .overlay {
            if on { Capsule().strokeBorder(c.ink, lineWidth: 1.5) } else if !soft { Capsule().strokeBorder(c.line) }
        }
        if let action {
            Button(action: action) { chip.contentShape(.capsule) }.buttonStyle(PressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
        } else {
            chip
        }
    }
}

/// Segmented control: a soft track, 3pt inset, the picked segment on surface with a light shadow. VoiceOver reads which
/// one is picked.
public struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    let small: Bool
    @Environment(\.kosha) private var theme

    public init(_ options: [(T, String)], selection: Binding<T>, small: Bool = false) {
        self.options = options
        _selection = selection
        self.small = small
    }

    public var body: some View {
        let c = theme.colors
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button {
                    withAnimation(theme.animation()) { selection = value }
                } label: {
                    Text(label)
                        .kFont(small ? (on ? .sans(13, .medium) : .small) : (on ? .head : .body))
                        .foregroundStyle(on ? c.ink : c.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: small ? 32 : 38)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9).fill(c.surface)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(c.soft, in: .rect(cornerRadius: 12))
    }
}

/// Switch: 46×28, knob 22, on in the accent.
public struct KSwitch: View {
    @Binding var isOn: Bool
    let label: String
    @Environment(\.kosha) private var theme

    public init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    public var body: some View {
        let c = theme.colors
        Button {
            withAnimation(theme.animation(.snappy(duration: 0.18))) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? c.brand : c.sel)
                .frame(width: 46, height: 28)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(c.dark ? Color(hex: 0xF3F3F4) : .white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                        .padding(3)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isToggle)
    }
}

/// Radio: 22, a 12pt dot in the selection colour.
public struct Radio: View {
    let on: Bool
    @Environment(\.kosha) private var theme
    public init(_ on: Bool) { self.on = on }
    public var body: some View {
        Circle().strokeBorder(on ? theme.colors.selection : theme.colors.line, lineWidth: 1.5)
            .frame(width: 22, height: 22)
            .overlay { if on { Circle().fill(theme.colors.selection).frame(width: 12, height: 12) } }
            .accessibilityHidden(true)
    }
}

/// Tick: 22, radius 7, the selection colour with a check.
public struct Tick: View {
    let on: Bool
    @Environment(\.kosha) private var theme
    public init(_ on: Bool) { self.on = on }
    public var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(on ? theme.colors.selection : .clear)
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(on ? theme.colors.selection : theme.colors.line, lineWidth: 1.5) }
            .frame(width: 22, height: 22)
            .overlay { if on { PhIcon("check", size: 14, color: theme.colors.onSelection) } }
            .accessibilityHidden(true)
    }
}

/// Stepper: − value +, in a bordered box, for "every N weeks".
public struct KStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String
    @Environment(\.kosha) private var theme

    public init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int> = 1...99) {
        self.label = label
        _value = value
        self.range = range
    }

    public var body: some View {
        HStack(spacing: 0) {
            IconButton("minus", label: L.app_stepper_less()) { value = max(range.lowerBound, value - 1) }
                .disabled(value <= range.lowerBound)
            Text("\(value)").kFont(.num).frame(minWidth: 28)
            IconButton("plus", label: L.app_stepper_more()) { value = min(range.upperBound, value + 1) }
                .disabled(value >= range.upperBound)
        }
        .padding(.horizontal, 2)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.colors.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }
}

/// A text field: at least 48 high, radius 14, a hairline; focused takes a 2pt ink border and an accent caret; an error
/// takes a bad border and its message below. The only place the system keyboard opens.
public struct KField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String?
    let error: String?
    let secure: Bool
    @FocusState private var focused: Bool
    @Environment(\.kosha) private var theme

    public init(_ placeholder: String, text: Binding<String>, icon: String? = nil, error: String? = nil, secure: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.icon = icon
        self.error = error
        self.secure = secure
    }

    public var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let icon { PhIcon(icon, size: 18, color: c.ink3) }
                Group {
                    if secure {
                        SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(c.ink3))
                    } else {
                        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(c.ink3))
                    }
                }
                .kFont(.sans(16, .regular))
                .tint(c.selection)
                .focused($focused)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(c.surface, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(error != nil ? c.bad : focused ? c.ink : c.line, lineWidth: focused || error != nil ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 14))
            .onTapGesture { focused = true }
            if let error { Text(error).kFont(.small).foregroundStyle(c.bad) }
        }
    }
}
