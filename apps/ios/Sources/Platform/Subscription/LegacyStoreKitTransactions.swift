import StoreKit

/// Acknowledge purchases begun on earlier versions, including delayed Ask to Buy approvals.
/// The features those products covered are available as soon as this build launches.
enum LegacyStoreKitTransactions {
    private static let productIDs: Set<String> = [
        "net.binjamshid.badan.pro.monthly",
        "net.binjamshid.badan.pro.yearly",
        "net.binjamshid.badan.pro.lifetime",
    ]

    static func observe() async {
        async let pending: Void = finishTransactions(Transaction.unfinished)
        await finishTransactions(Transaction.updates)
        await pending
    }

    private static func finishTransactions(_ transactions: Transaction.Transactions) async {
        for await result in transactions {
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID) else { continue }
            await transaction.finish()
        }
    }
}
