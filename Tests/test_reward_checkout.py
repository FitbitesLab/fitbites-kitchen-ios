"""Run production quote/invalidating methods against controlled async server replies."""
from pathlib import Path
import subprocess, tempfile, os
source=(Path(__file__).parents[1]/'FitbitesKitchen/ContentView.swift').read_text()
def block(marker):
 start=source.index(marker);end=source.index('{',start)+1;depth=1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
program='''import Foundation
struct Redemption { let sessionID: String; let customerID: Int }
struct POSCustomer { let id: Int }
enum POSPaymentMethod: String { case cash, bank }
enum POSOrderSource: String { case inStore = "in_store" }
struct POSRewardQuote: Equatable { let id: String }
struct POSSaleCartItem: Codable { let id: Int; init(line: Int) { id = line } }
struct Response { let rewardQuote: POSRewardQuote }
enum KitchenAPIError: Error { case serverMessage(Int, String, String) }
extension String { var nilIfBlank: String? { isEmpty ? nil : self } }
@MainActor final class Server {
 static var pending: [CheckedContinuation<Response, Error>] = []
 static var requests: [POSRewardQuoteRequest] = []
 static func waitFor(_ count: Int) async { while requests.count < count { await Task.yield() } }
 static func resolve(_ index: Int, _ id: String) { pending[index].resume(returning: Response(rewardQuote: POSRewardQuote(id: id))) }
}
@MainActor struct KitchenAPIClient {
 let baseURL: String; let token: String; let posSessionToken: String
 func quoteRewardSale(_ request: POSRewardQuoteRequest) async throws -> Response {
  Server.requests.append(request)
  return try await withCheckedThrowingContinuation { Server.pending.append($0) }
 }
}
'''+block('struct POSRewardQuoteRequest:')+'''
@MainActor final class Store {
 var activeRewardRedemption: Redemption? = Redemption(sessionID: "session-a", customerID: 88)
 var activeRewardQuote: POSRewardQuote?
 var rewardQuoteRevision = UUID()
 var rewardCheckoutToken: String? = "checkout-a"
 var cartLines = [1]
 var staffSessionToken = "staff"
 var isConnected = false
 func showSaleMessage(_ text: String) {}
 func currentRewardCheckoutToken() -> String { rewardCheckoutToken! }
'''+block('fileprivate func quoteRewardSale(')+'\n'+block('private func invalidateRewardQuote(').replace('private func','func')+'''
 func quote() async throws -> POSRewardQuote {
  try await quoteRewardSale(baseURL: "https://fitbites.com.vn", token: "test", paymentMethod: .cash,
    orderSource: .inStore, externalReference: "", customer: nil, discountPercent: 0, notes: "", rewardLineKey: "line-1")
 }
}
@main struct Tests {
 @MainActor static func main() async throws {
  let store=Store()
  let first=Task { try await store.quote() }
  await Server.waitFor(1)
  assert(Server.requests[0].customerID == 88)
  assert(Server.requests[0].rewardRedemptionSessionID == "session-a")
  store.cartLines=[2]; store.invalidateRewardQuote()
  let second=Task { try await store.quote() }
  await Server.waitFor(2)
  Server.resolve(1,"new")
  _ = try await second.value
  Server.resolve(0,"old")
  do { _ = try await first.value; assertionFailure("Old response accepted") } catch is CancellationError {} 
  assert(store.activeRewardQuote?.id == "new")
  assert(Server.requests[1].cart[0].id == 2)
  let cancelled=Task { try await store.quote() }
  await Server.waitFor(3); cancelled.cancel(); Server.resolve(2,"cancelled")
  do { _ = try await cancelled.value; assertionFailure("Cancelled response accepted") } catch is CancellationError {}
  assert(store.activeRewardQuote?.id == "new")
  let switched=Task { try await store.quote() }
  await Server.waitFor(4)
  store.activeRewardRedemption=Redemption(sessionID:"other",customerID:99)
  Server.resolve(3,"wrong-session")
  do { _ = try await switched.value; assertionFailure("Other session accepted") } catch is CancellationError {}
  store.invalidateRewardQuote(clearRedemption:true)
  assert(store.activeRewardQuote == nil && store.activeRewardRedemption == nil && store.rewardCheckoutToken == nil)
  do { _ = try await store.quote(); assertionFailure("Missing reward accepted") } catch is KitchenAPIError {}
  assert(Server.requests.count == 4)
  print("PASS: latest preview wins; cancelled and changed-session responses discarded; original customer and checkout identifiers preserved; missing rewards make no request")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='reward-checkout-tests-') as t:
 p=Path(t);(p/'tests.swift').write_text(program)
 env={**os.environ,'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
 subprocess.run(['/usr/bin/xcrun','swiftc','-parse-as-library','-module-cache-path',str(p/'cache'),str(p/'tests.swift'),'-o',str(p/'tests')],env=env,check=True)
 subprocess.run([str(p/'tests')],check=True)
