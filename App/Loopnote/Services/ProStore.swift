import Foundation
import Observation
import StoreKit

/// Loopnote Pro: monthly / yearly subscription or a lifetime purchase (StoreKit 2).
@MainActor
@Observable
final class ProStore {
    static let shared = ProStore()

    static let monthly = "com.muratturna.loopnote.pro.monthly"
    static let yearly = "com.muratturna.loopnote.pro.yearly"
    static let lifetime = "com.muratturna.loopnote.pro.lifetime"
    static let subscriptionIDs = [monthly, yearly]

    static let freeNoteLimit = 10
    static let freeProjectLimit = 2

    private(set) var purchased: Set<String> = []
    /// TestFlight and development builds have every Pro feature unlocked.
    private(set) var isTestBuild = false
    var showPaywall = false

    var isPro: Bool { isTestBuild || !purchased.isEmpty }

    private var updates: Task<Void, Never>?

    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task {
            if case .verified(let app) = try? await AppTransaction.shared {
                isTestBuild = app.environment != .production
            }
            await refresh()
        }
    }

    func refresh() async {
        var owned = Set<String>()
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil { owned.insert(t.productID) }
        }
        purchased = owned
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    /// Returns true when allowed; otherwise opens the paywall.
    @discardableResult
    func require() -> Bool {
        if isPro { return true }
        showPaywall = true
        return false
    }
}
