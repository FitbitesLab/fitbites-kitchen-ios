"""Exercise production quotation code on a booted iOS simulator, with a fake printer.

Run: python3 Tests/test_quotation.py
No printer/network connection, application install, or sale API is used.
"""
from pathlib import Path
import os
import subprocess
import tempfile

source = (Path(__file__).parents[1] / "FitbitesKitchen/ContentView.swift").read_text()


def block(marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


formatter_methods = [
    "static func formatQuotation(",
    "private static func escposRasterImageData(", "private static func prepareReceiptLogo(",
    "private static func append(", "private static func appendLine(", "private static func blank(",
    "private static func alignLeft(", "private static func alignCenter(", "private static func bold(",
    "private static func divider(", "private static func pair(", "private static func wrappedAmountLines(",
    "private static func wrap(", "private static func money(", "private static func printerText(",
    "private static func appendLogoIfAvailable(",
]
quotation_ui = block("private var quotationSection:")
assert ".disabled(lines.isEmpty || isPrintingQuotation)" in quotation_ui
assert quotation_ui.index("let snapshot =") < quotation_ui.index("Task {")
for forbidden in ["submit(", "clearCart", "quoteRewardSale(", "onIncrement", "onRemove", "paymentMethod ="]:
    assert forbidden not in quotation_ui
for current_value in ["line.unitPrice(for: orderSource)", "line.lineTotal(for: orderSource)",
                      "subtotal: checkoutSubtotal", "total: payableTotal", "?? discountAmount"]:
    assert current_value in quotation_ui

harness = r'''
import Foundation
import UIKit
extension UIImage {
__CROP__
}
__SNAPSHOT__
__RECEIPT_ITEMS__
private enum PrintReceiptResult: Equatable { case printed, skipped, failed(String) }
enum PrintReceiptFormatter {
    private static let esc = UInt8(0x1b), gs = UInt8(0x1d), lf = UInt8(0x0a)
__FORMATTER__
}
@MainActor struct NetworkReceiptPrinter {
    let host: String
    let port: Int
    static var sent = [Data]()
    static var fail = false
    static var whileSending: (() -> Void)?
    func print(_ data: Data) async throws {
        Self.whileSending?()
        if Self.fail { throw URLError(.notConnectedToInternet) }
        Self.sent.append(data)
    }
}
@MainActor final class Printer {
    var printerHost = "test-printer"
    var printerPort = 9100
    var paperWidth = 80
    var receiptLogoURL: URL?
    var receiptLogoScale = 1.0
    // No sale, payment, print-job, cart, or business mutation methods are available.
__PRINT__
}

@main struct Regression {
    @MainActor static func main() async throws {
        var cart = [POSQuotationSnapshot.Item(name: "Oats", sku: nil, category: nil, quantity: 2,
            baseUnitPrice: 45000, unitPrice: 62000, lineTotal: 124000,
            toppings: [PrintReceiptTopping(name: "Almond butter", sku: nil, category: nil,
                       quantity: 2, unitPrice: 17000, lineTotal: 34000)])]
        let snapshot = POSQuotationSnapshot(items: cart, subtotal: 124000, discount: 10000,
                                            marketplaceDeduction: 20000, rewardDiscount: 15000, total: 79001)
        // Deliberately supply a total that cannot be derived from the rows: formatter must copy it.
        for width in [58, 80] {
            // Regression: the product is 55,000; its three toppings add 85,000.
            for quantity in [1, 2] {
                let multiplier = Double(quantity)
                let item = PrintReceiptItem(name: "CappuccinOats", sku: nil, category: nil,
                    quantity: quantity, baseUnitPrice: 55000, unitPrice: 140000, lineTotal: 140000 * multiplier,
                    toppings: [30000.0, 25000.0, 30000.0].enumerated().map { index, price in
                        PrintReceiptTopping(name: "Topping \(index + 1)", sku: nil, category: nil,
                            quantity: quantity, unitPrice: price, lineTotal: price * multiplier)
                    })
                let bill = POSQuotationSnapshot(items: [item], subtotal: item.lineTotal, discount: 0,
                    marketplaceDeduction: 0, rewardDiscount: 0, total: item.lineTotal)
                let output = String(decoding: try PrintReceiptFormatter.formatQuotation(bill, paperWidth: width), as: UTF8.self)
                let rows = output.components(separatedBy: "\n")
                let product = rows.first { $0.contains("CappuccinOats") }!
                assert(product.contains("\(Int(55000 * multiplier).formatted()) VND"))
                for (index, price) in [30000.0, 25000.0, 30000.0].enumerated() {
                    let row = rows.first { $0.contains("Topping \(index + 1)") }!
                    assert(row.contains("\(Int(price * multiplier).formatted()) VND"))
                }
                assert(rows.first { $0.contains("TOTAL") }!.contains("\(Int(item.lineTotal).formatted()) VND"))
            }
            let data = try PrintReceiptFormatter.formatQuotation(snapshot, paperWidth: width)
            let bytes = [UInt8](data)
            var text = Data()
            var i = 0
            var rasters = 0
            while i < bytes.count {
                if i + 8 <= bytes.count && Array(bytes[i..<i+4]) == [0x1d, 0x76, 0x30, 0] {
                    let rowBytes = Int(bytes[i+4]) + Int(bytes[i+5]) * 256
                    let height = Int(bytes[i+6]) + Int(bytes[i+7]) * 256
                    assert(rowBytes * 8 <= (width == 58 ? 384 : 576))
                    let pixels = bytes[(i+8)..<(i+8+rowBytes*height)]
                    assert(pixels.contains { $0 != 0 }, "Heading must contain visible text")
                    i += 8 + rowBytes * height
                    rasters += 1
                } else {
                    text.append(bytes[i]); i += 1
                }
            }
            assert(rasters == 0, "Quotation text must use native text, never raster headings")
            let printed = String(decoding: text, as: UTF8.self)
            let timestamp = DateFormatter()
            timestamp.locale = Locale(identifier: "en_US_POSIX")
            timestamp.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
            timestamp.dateFormat = "HH:mm dd/MM/yyyy"
            let dateText = timestamp.string(from: snapshot.createdAt)
            assert(printed.components(separatedBy: dateText).count == 2)
            assert(printed.components(separatedBy: "For Order Review Only").count == 2)
            let header = printed.components(separatedBy: String(repeating: "-", count: width == 58 ? 32 : 48))[0]
            assert(!header.contains("\n\n"), "No empty lines between header elements")
            assert(header.contains(dateText + "\n\u{1b}E\u{1}For Order Review Only\n"))
            assert(!header.contains("PROVISIONAL BILL") && !header.contains("proof of payment"))
            assert(printed.range(of: "Not proof of payment.")!.lowerBound > printed.range(of: "TOTAL")!.lowerBound)
            assert(printed.contains("FITBITES"), "Missing logo must retain the brand name")
            assert(printed.contains("2 x Oats") && printed.contains("Almond butter"))
            let productLine = printed.components(separatedBy: "\n").first { $0.contains("2 x Oats") }!
            let toppingLine = printed.components(separatedBy: "\n").first { $0.contains("Almond butter") }!
            assert(productLine.contains("\(Int(90000).formatted()) VND"))
            assert(toppingLine.contains("\(Int(34000).formatted()) VND"))
            assert(!printed.contains("Unit price:"))
            assert(printed.contains("\(Int(124000).formatted()) VND"))
            assert(printed.contains("\(Int(79001).formatted()) VND"), "Never recalculate the total")
            for forbidden in ["Receipt no.", "Payment", "Cashier", "paid", "VNPay"] {
                assert(!printed.contains(forbidden))
            }
            assert(!text.containsSubsequence([0x1d, 0x28, 0x6b]), "No payment QR commands")
        }

        let printer = Printer()
        // A supplied logo must be rendered before the title, with the same receipt settings.
        let logoURL = URL(fileURLWithPath: "__LOGO_PATH__")
        let branded = try PrintReceiptFormatter.formatQuotation(snapshot, paperWidth: 80, logoURL: logoURL)
        let unbranded = try PrintReceiptFormatter.formatQuotation(snapshot, paperWidth: 80)
        assert(branded != unbranded)
        assert(Array(branded.prefix(9)) == [0x1b, 0x40, 0x1b, 0x61, 1, 0x1d, 0x76, 0x30, 0])
        let defaultsBefore = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        NetworkReceiptPrinter.whileSending = {
            // Cart edits and checkout state are independent of the captured print data.
            cart.removeAll()
            cart.append(.init(name: "New item", sku: nil, category: nil, quantity: 1,
                              baseUnitPrice: 1, unitPrice: 1, lineTotal: 1, toppings: []))
        }
        let success = await printer.printQuotation(snapshot)
        assert(success == .printed && NetworkReceiptPrinter.sent.count == 1)
        assert(cart.first?.name == "New item" && snapshot.items.first?.name == "Oats")
        let expected = try PrintReceiptFormatter.formatQuotation(snapshot, paperWidth: 80)
        assert(NetworkReceiptPrinter.sent[0] == expected)

        NetworkReceiptPrinter.whileSending = nil
        NetworkReceiptPrinter.fail = true
        let failure = await printer.printQuotation(snapshot)
        guard case .failed = failure else { fatalError("Expected print failure") }
        assert(cart.first?.name == "New item" && NetworkReceiptPrinter.sent.count == 1)
        assert(defaultsBefore.isEqual(to: UserDefaults.standard.dictionaryRepresentation()))
        let empty = POSQuotationSnapshot(items: [], subtotal: 0, discount: 0,
                                        marketplaceDeduction: 0, rewardDiscount: 0, total: 0)
        guard case .failed = await printer.printQuotation(empty) else { fatalError("Empty cart printed") }
        printer.printerPort = 70000
        guard case .failed = await printer.printQuotation(snapshot) else { fatalError("Invalid port accepted") }
        assert(NetworkReceiptPrinter.sent.count == 1)
        print("PASS: 58/80mm formatting, compact native header, single timestamp/review line, supplied prices/totals, no receipt/QR, immutable snapshot, editable cart, success/failure isolation, empty cart, invalid settings")
    }
}
extension Data {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        range(of: Data(needle)) != nil
    }
}
'''.replace("__SNAPSHOT__", block("struct POSQuotationSnapshot {"))
harness = harness.replace("__FORMATTER__", "\n".join(block(m) for m in formatter_methods))
harness = harness.replace("__RECEIPT_ITEMS__", block("struct PrintReceiptItem:") + "\n" + block("struct PrintReceiptTopping:"))
harness = harness.replace("__PRINT__", block("fileprivate func printQuotation("))
harness = harness.replace("__CROP__", block("func croppedToVisiblePixels("))
harness = harness.replace("__LOGO_PATH__", str(Path(__file__).parents[1] / "FitbitesKitchen/Assets.xcassets/EmberOSLogo.imageset/emberos-logo.png"))

with tempfile.TemporaryDirectory(prefix="quotation-regression-") as directory:
    path = Path(directory)
    (path / "Regression.swift").write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], env=env, text=True).strip()
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-sdk", sdk,
                    "-target", "arm64-apple-ios26.5-simulator", "-module-cache-path", str(path / "cache"),
                    str(path / "Regression.swift"), "-o", str(path / "regression")], check=True, env=env)
    subprocess.run(["xcrun", "simctl", "spawn", "booted", str(path / "regression")], check=True, env=env)
