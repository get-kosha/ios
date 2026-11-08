import SwiftUI
import Model
import Store
import Design

// Placeholder until its milestone builds it.
struct ActivityScreen: View { public var body: some View { Text(String(describing: Self.self)).kFont(.title) } }
struct TagViewScreen: View { let tag: String?; let eventId: String?; var body: some View { Text("TagView") } }
struct TxDetailScreen: View { let id: String; var body: some View { Text("TxDetail") } }
struct TransferDetailScreen: View { let id: String; var body: some View { Text("TransferDetail") } }
