import SwiftUI
import Model
import Store
import Design

// Placeholder until its milestone builds it.
struct RecurringScreen: View { public var body: some View { Text(String(describing: Self.self)).kFont(.title) } }
struct RecurringDetailScreen: View { let id: String; var body: some View { Text("RecurringDetail") } }
struct RecurringFormScreen: View { let id: String?; let fromPayee: String?; let fromTransaction: String?; var body: some View { Text("RecurringForm") } }
