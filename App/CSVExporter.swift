import Foundation

/// CSV export, so the data is never trapped inside this app.
enum CSVExporter {
    static func write(_ transactions: [Transaction]) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]

        var lines = ["Date,Amount,Currency,Type,Merchant,Category,Account,Note,Reference"]
        for transaction in transactions.sorted(by: { $0.date > $1.date }) {
            let fields = [
                formatter.string(from: transaction.date),
                "\(transaction.amount)",
                transaction.currencyCode,
                transaction.isCredit ? "Credit" : "Debit",
                transaction.merchant,
                transaction.category?.name ?? "",
                transaction.account?.name ?? "",
                transaction.note,
                transaction.reference ?? "",
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }

        let name = "ExpLog-\(formatter.string(from: .now)).csv"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
