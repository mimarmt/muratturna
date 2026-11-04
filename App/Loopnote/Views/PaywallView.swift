import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    private let store = ProStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(Theme.amber)
                        .padding(.top, 12)
                    Text("Loopnote Pro").font(Theme.title(.largeTitle))
                    Text("Notes that never let you forget, without limits.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 14) {
                        Feature(symbol: "infinity", text: "Unlimited notes and projects")
                        Feature(symbol: "alarm", text: "Critical notes that ring through Silent mode")
                        Feature(symbol: "waveform.badge.plus", text: "Natural ElevenLabs voices and your own voice")
                        Feature(symbol: "person.2.wave.2", text: "Meeting minutes with speakers and actions")
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.secondary.opacity(0.08)))

                    SubscriptionStoreView(productIDs: ProStore.subscriptionIDs)
                        .subscriptionStoreButtonLabel(.multiline)
                        .storeButton(.visible, for: .restorePurchases)
                        .frame(minHeight: 260)

                    ProductView(id: ProStore.lifetime) {
                        Image(systemName: "seal.fill").foregroundStyle(Theme.amber)
                    }
                    .productViewStyle(.compact)
                    .padding(.horizontal)

                    HStack(spacing: 18) {
                        Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Link("Privacy Policy", destination: AppLinks.privacy)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
            }
            .onInAppPurchaseCompletion { _, _ in
                await store.refresh()
                if store.isPro { dismiss() }
            }
        }
    }

    private struct Feature: View {
        let symbol: String
        let text: LocalizedStringKey
        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: symbol).frame(width: 26).foregroundStyle(Theme.amber)
                Text(text)
            }
        }
    }
}

enum AppLinks {
    /// Replaced with the published page during App Store preparation.
    static let privacy = URL(string: "https://github.com/mimarmt/muratturna/blob/main/docs/PRIVACY.md")!
}
