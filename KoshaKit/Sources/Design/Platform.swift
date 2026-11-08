import SwiftUI

// iOS-only modifiers behind one name each, so KoshaKit also builds for the Mac and `swift test` runs there. Screens use
// these instead of the iOS modifiers directly.

public enum KeyboardKind: Sendable { case text, url, email, number, search }

extension View {
    /// Hides the system navigation bar: Kosha draws its own headers.
    public func hideNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// The system keyboard for words, and how it capitalises.
    public func keyboard(_ kind: KeyboardKind, capitalise: Bool = true) -> some View {
        #if os(iOS)
        let type: UIKeyboardType = switch kind {
        case .text: .default
        case .url: .URL
        case .email: .emailAddress
        case .number: .numberPad
        case .search: .webSearch
        }
        return keyboardType(type)
            .textInputAutocapitalization(capitalise && kind == .text ? .sentences : .never)
            .autocorrectionDisabled(kind != .text)
        #else
        return self
        #endif
    }

    /// A full-screen cover on iOS; a sheet on the Mac.
    public func fullScreen<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }

    public func fullScreen<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}
