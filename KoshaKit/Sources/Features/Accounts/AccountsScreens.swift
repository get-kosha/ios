import SwiftUI
import Model
import Store
import Design

// Placeholder until its milestone builds it.
struct AccountsScreen: View { public var body: some View { Text(String(describing: Self.self)).kFont(.title) } }
struct AccountDetailScreen: View { let id: String; var body: some View { Text("AccountDetail") } }
struct InvestmentDetailScreen: View { let id: String; var body: some View { Text("InvestmentDetail") } }
struct AccountFormScreen: View { let id: String?; var body: some View { Text("AccountForm") } }
struct FixBalanceScreen: View { let id: String; var body: some View { Text("FixBalance") } }
struct ExchangesScreen: View { public var body: some View { Text(String(describing: Self.self)).kFont(.title) } }
