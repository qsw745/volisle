// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Observation
import StoreKit
import os

/// The one-time "盘屿 Pro" purchase. Only the app looks at it: it decides what
/// the app writes for the extension (StoreProSettings), never whether a disk is
/// written. A purchase lost or revoked takes effect at the next mount.
@MainActor @Observable final class StorePurchase {
    static let productID = "top.qisw.volisle.mas.pro"

    /// The last answer, so the window does not flicker to "not bought" before StoreKit replies.
    private(set) var unlocked = UserDefaults.standard.bool(forKey: StorePurchase.cacheKey) {
        didSet { UserDefaults.standard.set(unlocked, forKey: Self.cacheKey) }
    }
    private(set) var product: Product?
    private(set) var working = false
    /// What went wrong with the last purchase or restore, for the owner.
    private(set) var problem: String?
    /// Why the product could not be shown; cleared by a successful lookup.
    private(set) var productProblem: String?
    /// The purchase state changed; `revoked`: refunded or revoked, not merely not found.
    @ObservationIgnored var onChange: ((_ unlocked: Bool, _ revoked: Bool) -> Void)?
    @ObservationIgnored private var updates: Task<Void, Never>?

    private static let cacheKey = "ProUnlocked"

    func start() {
        guard updates == nil else { return }
        // Purchases made elsewhere (another Mac, Family Sharing), refunds and revocations.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await loadProduct(); await refresh() }
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
            productProblem = product == nil ? String(localized: "暂时无法从 App Store 取得盘屿 Pro 的信息，请稍后再试。") : nil
        } catch {
            productProblem = String(localized: "暂时无法连接 App Store：\(error.localizedDescription)")
        }
    }

    /// Owned and verified. Transactions are kept on this Mac, so this works offline.
    /// An entitlement that fails verification (a wrong clock, a StoreKit hiccup)
    /// leaves the last answer alone rather than taking away what was bought.
    func refresh() async {
        var owned = false, unverified = false
        #if VOLISLE_TEST_PRO
        // Local test candidates only (scripts/store/build-local-candidate.sh with VOLISLE_STORE_TEST_PRO=1):
        // a Developer ID build cannot buy. build-store-package.sh refuses a bundle containing this text.
        owned = true
        Logger(subsystem: "top.qisw.volisle.mas", category: "purchase").notice("测试构建：盘屿 Pro 视为已购买")
        #endif
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction) where transaction.productID == Self.productID: owned = true
            case .unverified(let transaction, _) where transaction.productID == Self.productID: unverified = true
            default: break
            }
        }
        if !owned && unverified { return }
        var revoked = false
        if !owned, case .verified(let latest)? = await Transaction.latest(for: Self.productID) {
            revoked = latest.revocationDate != nil
        }
        guard owned != unlocked || revoked else { return }
        unlocked = owned
        onChange?(owned, revoked)
    }

    /// `buy` is the view's PurchaseAction, which shows the confirmation over the right window.
    func purchase(_ buy: (Product) async throws -> Product.PurchaseResult) async {
        guard let product, !working else { return }
        working = true
        problem = nil
        defer { working = false }
        do {
            switch try await buy(product) {
            case .success(.verified(let transaction)):
                await transaction.finish()
                await refresh()
            case .success(.unverified):
                problem = String(localized: "App Store 返回的购买记录无法验证。请点“恢复购买”再试一次。")
            case .pending:
                problem = String(localized: "购买正在等待批准（例如“询问后购买”），批准后会自动解锁。")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            problem = String(localized: "没有完成购买：\(error.localizedDescription)")
        }
    }

    func restore() async {
        guard !working else { return }
        working = true
        problem = nil
        defer { working = false }
        do {
            try await AppStore.sync()
            await refresh()
            if !unlocked { problem = String(localized: "这个 Apple 账户没有购买过盘屿 Pro。") }
        } catch StoreKitError.userCancelled {
        } catch {
            problem = String(localized: "没有完成恢复：\(error.localizedDescription)")
        }
    }
}
