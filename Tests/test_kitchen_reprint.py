"""Run production reprint orchestration with read-only API and printer doubles.
Run from the project directory: python3 Tests/test_kitchen_reprint.py
"""
from pathlib import Path
import os
import subprocess
import tempfile

source = (Path(__file__).parents[1] / 'FitbitesKitchen/ContentView.swift').read_text()


def block(marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


assert 'KitchenReceiptReprintButton(saleID: order.id)' in source
assert 'KitchenReceiptReprintButton(saleID: ticket.id)' in source
harness = r'''
import Foundation
private enum PrintReceiptResult: Equatable { case printed, failed(String) }
struct PrintClaimRequest: Encodable {}
struct Receipt: Decodable { let saleID: Int }
struct Payload: Decodable { let receipt: Receipt; let originalBytes: Data }
struct PrintReceiptCopyResponse: Decodable { let payload: Payload }
@MainActor struct PrintJobAPIClient {
    let baseURL: String
    let token: String
    static var fail = false
    static var receiptID = 42
    static var requests = [String]()
    __FETCH__
    private func request<Response: Decodable, Body: Encodable>(path: String, method: String, body: Body?) async throws -> Response {
        assert(method == "GET" && body == nil)
        assert(path == "/api/print-jobs/sale/42/receipt")
        Self.requests.append(path)
        if Self.fail { throw URLError(.notConnectedToInternet) }
        return PrintReceiptCopyResponse(payload: Payload(receipt: Receipt(saleID: Self.receiptID), originalBytes: Data("saved-receipt".utf8))) as! Response
    }
}
enum PrintReceiptFormatter {
    static func format(_ payload: Payload, paperWidth: Int, logoURL: URL?, logoScale: Double) -> Data {
        payload.originalBytes
    }
}
@MainActor struct NetworkReceiptPrinter {
    let host: String
    let port: Int
    static var fail = false
    static var copies = [Data]()
    static var onSend: (() async -> Void)?
    func print(_ data: Data) async throws {
        if let callback = Self.onSend { await callback() }
        if Self.fail { throw URLError(.cannotConnectToHost) }
        Self.copies.append(data)
    }
}
@MainActor final class Store {
    var isReprintingReceipt = false
    var serverURL = "test"
    var printToken = "test"
    var printerHost = "test"
    var printerPort = 9100
    var paperWidth = 80
    var receiptLogoURL: URL?
    var receiptLogoScale = 1.0
    var statusMessage = "ready"
    var valid = true
    func validateSettings() -> Bool { valid }
    // Business state and print job mutation methods intentionally do not exist here.
    __REPRINT__
}
@main struct Regression {
    @MainActor static func main() async {
        let store = Store()
        let defaultsBefore = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        for _ in 0..<2 {
            let result = await store.reprintSaleReceipt(saleID: 42)
            assert(result == .printed && !store.isReprintingReceipt)
        }
        assert(NetworkReceiptPrinter.copies == [Data("saved-receipt".utf8), Data("saved-receipt".utf8)])
        NetworkReceiptPrinter.fail = true
        guard case .failed = await store.reprintSaleReceipt(saleID: 42) else { fatalError() }
        assert(!store.isReprintingReceipt && NetworkReceiptPrinter.copies.count == 2)
        NetworkReceiptPrinter.fail = false
        PrintJobAPIClient.fail = true
        guard case .failed = await store.reprintSaleReceipt(saleID: 42) else { fatalError() }
        assert(!store.isReprintingReceipt && NetworkReceiptPrinter.copies.count == 2)
        PrintJobAPIClient.fail = false
        PrintJobAPIClient.receiptID = 99
        guard case .failed = await store.reprintSaleReceipt(saleID: 42) else { fatalError() }
        assert(NetworkReceiptPrinter.copies.count == 2)
        PrintJobAPIClient.receiptID = 42
        NetworkReceiptPrinter.onSend = {
            guard case .failed = await store.reprintSaleReceipt(saleID: 42) else { fatalError("Duplicate concurrent print") }
        }
        let retried = await store.reprintSaleReceipt(saleID: 42)
        assert(retried == .printed && NetworkReceiptPrinter.copies.count == 3)
        assert(!store.isReprintingReceipt && store.statusMessage == "ready")
        assert(defaultsBefore.isEqual(to: UserDefaults.standard.dictionaryRepresentation()))
        print("PASS: repeat copies, GET-only API, original receipt bytes, failure/retry, mismatched sale, duplicate tap guard, unchanged saved state")
    }
}
'''.replace('__FETCH__', block('func fetchReceipt(')).replace('__REPRINT__', block('fileprivate func reprintSaleReceipt('))

with tempfile.TemporaryDirectory(prefix='kitchen-reprint-') as directory:
    path = Path(directory)
    (path / 'Regression.swift').write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'),
                    str(path / 'Regression.swift'), '-o', str(path / 'regression')], check=True, env=env)
    subprocess.run([str(path / 'regression')], check=True)
