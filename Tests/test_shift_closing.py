"""Run the production shift preparation method with deterministic API/queue doubles.

Run: python3 Tests/test_shift_closing.py (from the Xcode project directory).
The adjacent PHP regression can run in Laravel's tests/Feature directory.
"""
from pathlib import Path
import os
import subprocess
import tempfile

source = (Path(__file__).parents[1] / "FitbitesKitchen/ContentView.swift").read_text()
method = source.split("    func prepareShiftClosing(", 1)[1].split("    func endShift(", 1)[0]
method = "    func prepareShiftClosing(" + method

harness = r'''
import Foundation

struct POSShiftEnvelope {
    var isOpen = true
    var shift: Int? = 1
    var recap: Double? = 625000
}
struct POSShiftResponse { let shift: POSShiftEnvelope }
@MainActor enum POSQueuedSaleStore {
    static var queue = [Int]()
    static func load() -> [Int] { queue }
}
@MainActor enum POSQueuedShiftMutationStore {
    static var queue = [Int]()
    static func load() -> [Int] { queue }
}
@MainActor struct KitchenAPIClient {
    let baseURL: String
    let token: String
    let posSessionToken: String
    static var calls = 0
    static var response = POSShiftEnvelope()
    static var fail = false
    func fetchPOSShift() async throws -> POSShiftResponse {
        Self.calls += 1
        if Self.fail { throw URLError(.notConnectedToInternet) }
        return POSShiftResponse(shift: Self.response)
    }
}
@MainActor final class Store {
    var refreshTask: Task<Void, Never>?
    var shiftSyncTask: Task<Void, Never>?
    var saleSyncTask: Task<Void, Never>?
    var staffSessionToken = "staff"
    var errorMessage: String?
    var isConnected = true
    var cachedShift = POSShiftEnvelope(recap: 850000)
    func applyLocalShift(_ shift: POSShiftEnvelope) { cachedShift = shift }
__METHOD__
}
@main struct Regression {
    @MainActor static func main() async {
        let store = Store()
        // A cancelled and deleted sale have already disappeared on the server.
        let current = await store.prepareShiftClosing(baseURL: "test", token: "device")
        assert(current?.recap == 625000)
        assert(store.cachedShift.recap == 625000)

        KitchenAPIClient.fail = true
        let offline = await store.prepareShiftClosing(baseURL: "test", token: "device")
        assert(offline == nil, "Offline must never return cached money for closing")
        assert(store.errorMessage != nil && !store.isConnected)
        KitchenAPIClient.fail = false

        POSQueuedSaleStore.queue = [1]
        let calls = KitchenAPIClient.calls
        let pendingSale = await store.prepareShiftClosing(baseURL: "test", token: "device")
        assert(pendingSale == nil && KitchenAPIClient.calls == calls)
        POSQueuedSaleStore.queue = []
        POSQueuedShiftMutationStore.queue = [1]
        let pendingCash = await store.prepareShiftClosing(baseURL: "test", token: "device")
        assert(pendingCash == nil && KitchenAPIClient.calls == calls)

        // Preparation must wait for older writes/refreshes before its final read.
        POSQueuedSaleStore.queue = [1]
        store.refreshTask = Task { @MainActor in
            await Task.yield()
            store.cachedShift = POSShiftEnvelope(recap: 850000)
        }
        store.shiftSyncTask = Task { @MainActor in
            await Task.yield()
            POSQueuedShiftMutationStore.queue = []
        }
        store.saleSyncTask = Task { @MainActor in
            await Task.yield()
            POSQueuedSaleStore.queue = []
        }
        let synced = await store.prepareShiftClosing(baseURL: "test", token: "device")
        assert(synced?.recap == 625000 && store.cachedShift.recap == 625000)
        assert(store.errorMessage == nil)

        KitchenAPIClient.response = POSShiftEnvelope(isOpen: false, shift: nil, recap: nil)
        let closed = await store.prepareShiftClosing(baseURL: "test", token: "device")
        assert(closed == nil)
        KitchenAPIClient.response = POSShiftEnvelope(recap: nil)
        let missing = await store.prepareShiftClosing(baseURL: "test", token: "device")
        assert(missing == nil)
        print("PASS: fresh totals, offline, pending sales, pending cash, sync ordering, closed shift, missing recap")
    }
}
'''.replace("__METHOD__", method)

with tempfile.TemporaryDirectory(prefix="shift-closing-") as directory:
    path = Path(directory)
    (path / "Regression.swift").write_text(harness)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(path / "cache"),
        str(path / "Regression.swift"), "-o", str(path / "regression"),
    ], check=True, env=env)
    subprocess.run([str(path / "regression")], check=True)
