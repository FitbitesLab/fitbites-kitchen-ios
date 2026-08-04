//
//  ContentView.swift
//  FitbitesKitchen
//
//  Native kitchen terminal for Ember OS.
//

import SwiftUI
import Combine
import AVFoundation
import UIKit
import CoreText

private enum AppSection {
    case kitchen
    case pos
}

struct ContentView: View {
    @StateObject private var store = KitchenStore()
    @StateObject private var posStore = POSStore()
    private let startsPolling: Bool
    @State private var selectedSection: AppSection = .kitchen
    @State private var selectedStatus: KitchenStatus? = nil
    @State private var selectedSource: KitchenSource? = nil
    @State private var selectedOrder: KitchenOrder?
    @State private var pendingOnlineOrderAction: OnlineOrderAction?
    @State private var pendingKitchenCancelOrder: KitchenOrder?
    @State private var settingsOpen = false
    @Namespace private var filterSelectionNamespace

    init(startsPolling: Bool = true) {
        GlacialFont.register()
        self.startsPolling = startsPolling
    }

    private var filteredOrders: [KitchenOrder] {
        store.orders
            .filter { selectedStatus == nil || $0.status == selectedStatus }
            .filter { selectedSource == nil || $0.source == selectedSource }
            .sorted { lhs, rhs in
                if lhs.status.priority == rhs.status.priority {
                    return lhs.elapsedMinutes > rhs.elapsedMinutes
                }

                return lhs.status.priority < rhs.status.priority
            }
    }

    private var visibleOnlineOrders: [KitchenOnlineOrder] {
        guard selectedSource == nil || selectedSource == .website else {
            return []
        }

        guard selectedStatus == nil || selectedStatus == .pending else {
            return []
        }

        return store.onlineOrders
    }

    private var showsOnlineOrders: Bool {
        selectedSource == nil || selectedSource == .website
            ? selectedStatus == nil || selectedStatus == .pending
            : false
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HeaderView(
                            activeCount: selectedSection == .kitchen ? store.orders.count : posStore.productCount,
                            readyCount: selectedSection == .kitchen ? store.summary.ready : posStore.categoryCount,
                            oldestMinutes: selectedSection == .kitchen ? store.oldestElapsedMinutes : nil,
                            isConnected: selectedSection == .kitchen ? store.isConnected : posStore.isConnected,
                            section: selectedSection
                        )

                        if selectedSection == .kitchen {
                            MetricsStrip(summary: store.summary)

                            FilterBar(
                                selectedSource: $selectedSource,
                                selectedStatus: $selectedStatus,
                                sources: store.availableSources,
                                namespace: filterSelectionNamespace
                            )

                            if let message = store.errorMessage {
                                ErrorBanner(message: message) {
                                    Task { await store.refresh(forceChime: false) }
                                }
                            }

                            if showsOnlineOrders {
                                OnlineOrderReviewSection(
                                    orders: visibleOnlineOrders,
                                    onAccept: { order in
                                        pendingOnlineOrderAction = .accept(order)
                                    },
                                    onDecline: { order in
                                        pendingOnlineOrderAction = .decline(order)
                                    }
                                )
                            }

                            QueueSection(
                                orders: filteredOrders,
                                isInitialLoading: store.isInitialLoading,
                                isRefreshing: store.isRefreshing,
                                onSelect: { selectedOrder = $0 },
                                onStatus: { order, status in
                                    handleStatus(order: order, status: status)
                                }
                            )
                        } else {
                            POSDashboardView(store: posStore, baseURL: store.baseURL, token: store.kitchenToken)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 44)
                    .padding(.bottom, 20)
                }
                .refreshable {
                    if selectedSection == .kitchen {
                        await store.refresh(forceChime: false)
                    } else {
                        await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken)
                    }
                }

                Menu {
                    Button {
                        selectedSection = .kitchen
                        selectedSource = nil
                        selectedStatus = nil
                        Task { await store.refresh(forceChime: false) }
                    } label: {
                        Label("Home", systemImage: "house")
                    }

                    Button {
                        selectedSection = .pos
                        Task { await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken) }
                    } label: {
                        Label("POS", systemImage: "cart")
                    }

                    Button {
                        settingsOpen = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    VStack(alignment: .center, spacing: 4) {
                        Capsule()
                            .frame(width: 16, height: 1.5)
                        Capsule()
                            .frame(width: 10, height: 1.5)
                        Capsule()
                            .frame(width: 16, height: 1.5)
                    }
                    .foregroundStyle(AppPalette.ink)
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
                .padding(.trailing, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if startsPolling {
                    store.start()
                }

                await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken)
            }
            .onDisappear {
                store.stop()
            }
            .sheet(item: $selectedOrder) { order in
                OrderDetailView(order: order) { status in
                    if status == .cancelled {
                        pendingKitchenCancelOrder = order
                        selectedOrder = nil
                    } else {
                        selectedOrder = nil
                        Task { await store.update(order: order, status: status) }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .alert(
                pendingOnlineOrderAction?.title ?? "",
                isPresented: Binding(
                    get: { pendingOnlineOrderAction != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingOnlineOrderAction = nil
                        }
                    }
                ),
                presenting: pendingOnlineOrderAction
            ) { action in
                Button(action.confirmLabel, role: action.role) {
                    let confirmedAction = action
                    pendingOnlineOrderAction = nil
                    Task {
                        switch confirmedAction {
                        case .accept(let order):
                            await store.acceptOnlineOrder(order)
                        case .decline(let order):
                            await store.rejectOnlineOrder(order)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingOnlineOrderAction = nil
                }
            } message: { action in
                Text(action.message)
            }
            .alert(
                "Cancel kitchen order?",
                isPresented: Binding(
                    get: { pendingKitchenCancelOrder != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingKitchenCancelOrder = nil
                        }
                    }
                ),
                presenting: pendingKitchenCancelOrder
            ) { order in
                Button("Cancel order", role: .destructive) {
                    pendingKitchenCancelOrder = nil
                    Task { await store.update(order: order, status: .cancelled) }
                }
                Button("Keep order", role: .cancel) {
                    pendingKitchenCancelOrder = nil
                }
            } message: { order in
                Text("Are you sure you want to cancel \(order.orderNumber)? This removes it from the active kitchen rail.")
            }
            .sheet(isPresented: $settingsOpen) {
                SettingsView(store: store)
                    .presentationDetents([.medium])
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func handleStatus(order: KitchenOrder, status: KitchenStatus) {
        if status == .cancelled {
            pendingKitchenCancelOrder = order
            return
        }

        Task { await store.update(order: order, status: status) }
    }
}

private enum OnlineOrderAction: Identifiable {
    case accept(KitchenOnlineOrder)
    case decline(KitchenOnlineOrder)

    var id: String {
        switch self {
        case .accept(let order):
            return "accept-\(order.id)"
        case .decline(let order):
            return "decline-\(order.id)"
        }
    }

    var title: String {
        switch self {
        case .accept:
            return "Accept online order?"
        case .decline:
            return "Decline online order?"
        }
    }

    var message: String {
        switch self {
        case .accept(let order):
            return "Are you sure you want to accept \(order.orderNumber)? It will move into the kitchen queue now."
        case .decline(let order):
            return "Are you sure you want to decline \(order.orderNumber)? The customer order request will be rejected."
        }
    }

    var confirmLabel: String {
        switch self {
        case .accept:
            return "Accept"
        case .decline:
            return "Decline"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .accept:
            return nil
        case .decline:
            return .destructive
        }
    }
}

@MainActor
final class KitchenStore: ObservableObject {
    @Published var onlineOrders: [KitchenOnlineOrder] = []
    @Published var orders: [KitchenOrder] = []
    @Published var summary = KitchenSummary.empty
    @Published var isInitialLoading = false
    @Published var isRefreshing = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var baseURL = UserDefaults.standard.string(forKey: "KitchenBaseURL") ?? "http://127.0.0.1:8000"
    @Published var kitchenToken = UserDefaults.standard.string(forKey: "KitchenToken") ?? ""
    @Published var chimeTone = KitchenChimeTone(
        rawValue: UserDefaults.standard.string(forKey: "KitchenChimeTone") ?? ""
    ) ?? .fitbites

    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var knownOrderIDs = Set<Int>()
    private var knownOnlineOrderIDs = Set<Int>()
    private var hasLoadedOnce = false
    private var alertingOrderIDs = Set<Int>()
    private let chime = KitchenChime()

    var oldestElapsedMinutes: Int? {
        orders.map(\.elapsedMinutes).max()
    }

    var availableSources: [KitchenSource] {
        Array(Set(orders.map(\.source))).sorted { $0.rawValue < $1.rawValue }
    }

    func start() {
        stop()

        pollTask = Task { [weak self] in
            guard let self else { return }
            await refresh(forceChime: false)

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await refresh(forceChime: true)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        chime.stop()
    }

    func saveSettings(baseURL: String, token: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kitchenToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.baseURL, forKey: "KitchenBaseURL")
        UserDefaults.standard.set(self.kitchenToken, forKey: "KitchenToken")

        knownOrderIDs.removeAll()
        knownOnlineOrderIDs.removeAll()
        Task { await refresh(forceChime: false) }
    }

    func playTestChime() {
        chime.play(tone: chimeTone)
    }

    func previewChimeTone(_ tone: KitchenChimeTone) {
        chime.stop()
        chime.play(tone: tone)
    }

    func stopChime() {
        chime.stop()
    }

    func saveChimeTone(_ tone: KitchenChimeTone) {
        chimeTone = tone
        UserDefaults.standard.set(tone.rawValue, forKey: "KitchenChimeTone")
    }

    func refresh(forceChime: Bool) async {
        guard refreshTask == nil else {
            return
        }

        refreshTask = Task { [weak self] in
            await self?.performRefresh(forceChime: forceChime)
        }

        await refreshTask?.value
        refreshTask = nil
    }

    private func performRefresh(forceChime: Bool) async {
        guard !kitchenToken.isEmpty else {
            errorMessage = "Add the kitchen token in Settings."
            isConnected = false
            isInitialLoading = false
            isRefreshing = false
            return
        }

        let firstLoad = !hasLoadedOnce
        if firstLoad {
            isInitialLoading = true
        } else {
            isRefreshing = true
        }

        do {
            let client = KitchenAPIClient(baseURL: baseURL, token: kitchenToken)
            let onlinePayload = try await client.fetchOnlineOrders()
            let kitchenPayload = try await client.fetchOrders()
            let incomingIDs = Set(kitchenPayload.orders.map(\.id))
            let incomingOnlineIDs = Set(onlinePayload.onlineOrders.map(\.id))
            let previousActiveCount = orders.count + onlineOrders.count
            let newOnlineIDs = incomingOnlineIDs.subtracting(knownOnlineOrderIDs)
            let alertingIDs = Set(kitchenPayload.orders.filter(\.isPastAlertThreshold).map(\.id))
            let newAlertingIDs = alertingIDs.subtracting(alertingOrderIDs)

            onlineOrders = onlinePayload.onlineOrders
            orders = kitchenPayload.orders
            summary = kitchenPayload.summary
            knownOrderIDs = incomingIDs
            knownOnlineOrderIDs = incomingOnlineIDs
            alertingOrderIDs = alertingIDs
            errorMessage = nil
            isConnected = true
            hasLoadedOnce = true

            if forceChime && !newOnlineIDs.isEmpty {
                chime.play(tone: chimeTone)
            }

            if !firstLoad && (
                !newOnlineIDs.isEmpty ||
                previousActiveCount > 0 && onlinePayload.onlineOrders.isEmpty && kitchenPayload.orders.isEmpty ||
                !newAlertingIDs.isEmpty
            ) {
                Haptics.notification(.success)
            }
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }

        isInitialLoading = false
        isRefreshing = false
    }

    func update(order: KitchenOrder, status: KitchenStatus) async {
        if status == .cancelled {
            chime.stop()
        }

        do {
            let updated = try await KitchenAPIClient(baseURL: baseURL, token: kitchenToken).updateStatus(orderID: order.id, status: status)

            if let index = orders.firstIndex(where: { $0.id == updated.id }) {
                if updated.status == .completed || updated.status == .cancelled {
                    orders.remove(at: index)
                } else {
                    orders[index] = updated
                }
            }

            await refresh(forceChime: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acceptOnlineOrder(_ order: KitchenOnlineOrder) async {
        chime.stop()

        do {
            _ = try await KitchenAPIClient(baseURL: baseURL, token: kitchenToken).acceptOnlineOrder(orderID: order.id)
            knownOnlineOrderIDs.remove(order.id)
            await refresh(forceChime: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rejectOnlineOrder(_ order: KitchenOnlineOrder) async {
        chime.stop()

        do {
            _ = try await KitchenAPIClient(baseURL: baseURL, token: kitchenToken).rejectOnlineOrder(orderID: order.id)
            knownOnlineOrderIDs.remove(order.id)
            await refresh(forceChime: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class POSStore: ObservableObject {
    @Published var bootstrap: POSBootstrapResponse?
    @Published var cartLines: [POSCartLine] = []
    @Published var isInitialLoading = false
    @Published var isRefreshing = false
    @Published var isSubmitting = false
    @Published var isShiftSubmitting = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var saleMessage: String?

    private var refreshTask: Task<Void, Never>?

    var productCount: Int {
        bootstrap?.catalog.products.count ?? 0
    }

    var categoryCount: Int {
        bootstrap?.catalog.categories.count ?? 0
    }

    var cartItemCount: Int {
        cartLines.reduce(0) { $0 + $1.quantity }
    }

    var cartTotal: Double {
        cartLines.reduce(0) { $0 + $1.lineTotal }
    }

    func quantityInCart(for product: POSProduct) -> Int {
        cartLines
            .filter { $0.product.id == product.id }
            .reduce(0) { $0 + $1.quantity }
    }

    func add(product: POSProduct, toppings: [POSTopping]) {
        let lineID = POSCartLine.makeID(product: product, toppings: toppings)

        if let index = cartLines.firstIndex(where: { $0.id == lineID }) {
            cartLines[index].quantity += 1
        } else {
            cartLines.append(POSCartLine(product: product, toppings: toppings, quantity: 1))
        }

        Haptics.impact(.light)
    }

    func increment(line: POSCartLine) {
        guard let index = cartLines.firstIndex(where: { $0.id == line.id }) else { return }
        cartLines[index].quantity += 1
        Haptics.impact(.light)
    }

    func decrement(line: POSCartLine) {
        guard let index = cartLines.firstIndex(where: { $0.id == line.id }) else { return }

        if cartLines[index].quantity <= 1 {
            cartLines.remove(at: index)
        } else {
            cartLines[index].quantity -= 1
        }

        Haptics.impact(.light)
    }

    func clearCart() {
        cartLines.removeAll()
        Haptics.notification(.success)
    }

    func submitSale(
        baseURL: String,
        token: String,
        paymentMethod: POSPaymentMethod,
        orderSource: POSOrderSource,
        externalReference: String,
        customer: POSCustomer?,
        discountPercent: Double,
        notes: String
    ) async -> Bool {
        guard !cartLines.isEmpty else {
            errorMessage = "Add at least one product before checkout."
            return false
        }

        isSubmitting = true
        errorMessage = nil
        saleMessage = nil

        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token).submitPOSSale(
                POSCreateSaleRequest(
                    cart: cartLines.map(POSSaleCartItem.init(line:)),
                    paymentMethod: paymentMethod.rawValue,
                    orderSource: orderSource.rawValue,
                    externalOrderReference: externalReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : externalReference.trimmingCharacters(in: .whitespacesAndNewlines),
                    customerID: customer?.id,
                    discountPercent: max(0, min(discountPercent, 100)),
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : notes.trimmingCharacters(in: .whitespacesAndNewlines),
                    checkoutToken: "native-pos-\(UUID().uuidString)"
                )
            )

            saleMessage = response.message
            cartLines.removeAll()
            await refresh(baseURL: baseURL, token: token)
            Haptics.notification(.success)
            isSubmitting = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
            Haptics.notification(.error)
            isSubmitting = false
            return false
        }
    }

    func startShift(baseURL: String, token: String, openingCash: Double, notes: String) async -> Bool {
        await mutateShift(baseURL: baseURL, token: token) {
            try await KitchenAPIClient(baseURL: baseURL, token: token).startPOSShift(
                POSStartShiftRequest(
                    openingCash: openingCash,
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
    }

    func recordCashMovement(baseURL: String, token: String, type: POSCashMovementType, amount: Double, reason: String) async -> Bool {
        await mutateShift(baseURL: baseURL, token: token) {
            try await KitchenAPIClient(baseURL: baseURL, token: token).recordPOSCashMovement(
                POSCashMovementRequest(
                    type: type.rawValue,
                    amount: amount,
                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
    }

    func endShift(baseURL: String, token: String, closingCash: Double?, notes: String) async -> Bool {
        await mutateShift(baseURL: baseURL, token: token) {
            try await KitchenAPIClient(baseURL: baseURL, token: token).endPOSShift(
                POSEndShiftRequest(
                    closingCash: closingCash,
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
    }

    private func mutateShift(baseURL: String, token: String, action: () async throws -> POSShiftResponse) async -> Bool {
        guard !isShiftSubmitting else { return false }

        isShiftSubmitting = true
        errorMessage = nil
        saleMessage = nil

        do {
            let response = try await action()
            bootstrap = bootstrap.map {
                POSBootstrapResponse(operator: $0.operator, catalog: $0.catalog, shift: response.shift)
            }
            isConnected = true
            Haptics.notification(.success)
            isShiftSubmitting = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
            Haptics.notification(.error)
            isShiftSubmitting = false
            return false
        }
    }

    func refresh(baseURL: String, token: String) async {
        guard refreshTask == nil else {
            return
        }

        refreshTask = Task { [weak self] in
            await self?.performRefresh(baseURL: baseURL, token: token)
        }

        await refreshTask?.value
        refreshTask = nil
    }

    private func performRefresh(baseURL: String, token: String) async {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Add the kitchen token in Settings."
            isConnected = false
            isInitialLoading = false
            isRefreshing = false
            return
        }

        if bootstrap == nil {
            isInitialLoading = true
        } else {
            isRefreshing = true
        }

        do {
            bootstrap = try await KitchenAPIClient(baseURL: baseURL, token: token).fetchPOSBootstrap()
            errorMessage = nil
            isConnected = true
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }

        isInitialLoading = false
        isRefreshing = false
    }
}

struct KitchenAPIClient {
    let baseURL: String
    let token: String

    func fetchPOSBootstrap() async throws -> POSBootstrapResponse {
        try await request(path: "/api/pos/bootstrap", method: "GET", body: Optional<KitchenStatusRequest>.none)
    }

    func submitPOSSale(_ sale: POSCreateSaleRequest) async throws -> POSCreateSaleResponse {
        try await request(path: "/api/pos/sales", method: "POST", body: sale)
    }

    func searchPOSCustomers(search: String) async throws -> POSCustomersResponse {
        var components = URLComponents()
        components.path = "/api/pos/customers"
        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            components.queryItems = [URLQueryItem(name: "search", value: trimmedSearch)]
        }

        return try await request(
            path: components.string ?? "/api/pos/customers",
            method: "GET",
            body: Optional<KitchenStatusRequest>.none
        )
    }

    func createPOSCustomer(_ customer: POSCreateCustomerRequest) async throws -> POSCustomerResponse {
        try await request(path: "/api/pos/customers", method: "POST", body: customer)
    }

    func startPOSShift(_ shift: POSStartShiftRequest) async throws -> POSShiftResponse {
        try await request(path: "/api/pos/shift/start", method: "POST", body: shift)
    }

    func recordPOSCashMovement(_ movement: POSCashMovementRequest) async throws -> POSShiftResponse {
        try await request(path: "/api/pos/shift/cash", method: "POST", body: movement)
    }

    func endPOSShift(_ shift: POSEndShiftRequest) async throws -> POSShiftResponse {
        try await request(path: "/api/pos/shift/end", method: "POST", body: shift)
    }

    func fetchOnlineOrders() async throws -> KitchenOnlineOrdersResponse {
        try await request(path: "/api/kitchen/online-orders", method: "GET", body: Optional<KitchenStatusRequest>.none)
    }

    func fetchOrders() async throws -> KitchenOrdersResponse {
        try await request(path: "/api/kitchen/orders", method: "GET", body: Optional<KitchenStatusRequest>.none)
    }

    func acceptOnlineOrder(orderID: Int) async throws -> KitchenAcceptOnlineOrderResponse {
        try await request(
            path: "/api/kitchen/online-orders/\(orderID)/accept",
            method: "POST",
            body: Optional<KitchenStatusRequest>.none
        )
    }

    func rejectOnlineOrder(orderID: Int) async throws -> KitchenOnlineOrderResponse {
        try await request(
            path: "/api/kitchen/online-orders/\(orderID)/reject",
            method: "POST",
            body: Optional<KitchenStatusRequest>.none
        )
    }

    func updateStatus(orderID: Int, status: KitchenStatus) async throws -> KitchenOrder {
        let response: KitchenOrderResponse = try await request(
            path: "/api/kitchen/orders/\(orderID)/status",
            method: "PATCH",
            body: KitchenStatusRequest(status: status.rawValue)
        )

        return response.order
    }

    private func request<Response: Decodable, Body: Encodable>(path: String, method: String, body: Body?) async throws -> Response {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw KitchenAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Kitchen-Token")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KitchenAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 403 {
                throw KitchenAPIError.unauthorized
            }

            if let apiError = try? JSONDecoder().decode(KitchenAPIErrorResponse.self, from: data),
               let message = apiError.displayMessage {
                throw KitchenAPIError.serverMessage(httpResponse.statusCode, path, message)
            }

            throw KitchenAPIError.server(httpResponse.statusCode, path)
        }

        return try JSONDecoder.kitchen.decode(Response.self, from: data)
    }
}

private struct KitchenAPIErrorResponse: Decodable {
    let message: String?
    let errors: [String: [String]]?

    var displayMessage: String? {
        if let firstError = errors?.values.flatMap({ $0 }).first, !firstError.isEmpty {
            return firstError
        }

        guard let message, !message.isEmpty else {
            return nil
        }

        return message
    }
}

enum KitchenChimeTone: String, CaseIterable, Identifiable {
    case fitbites
    case brewing
    case carnet
    case morning

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitbites: "Fitbites Chime"
        case .brewing: "Brewing"
        case .carnet: "Carnet"
        case .morning: "Morning"
        }
    }

    var bundledAudio: (name: String, extension: String)? {
        switch self {
        case .fitbites:
            return ("fitbites-order-chime", "mp3")
        case .brewing:
            return ("fitbites-chime-brewing", "mp3")
        case .carnet:
            return ("fitbites-chime-carnet", "mp3")
        case .morning:
            return ("fitbites-chime-morning", "mp3")
        }
    }

    var systemSoundID: SystemSoundID {
        1005
    }
}

private final class KitchenChime: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?

    func play(tone: KitchenChimeTone) {
        if player?.isPlaying == true {
            return
        }

        guard let bundledAudio = tone.bundledAudio else {
            AudioServicesPlaySystemSound(tone.systemSoundID)
            return
        }

        guard let url = Bundle.main.url(forResource: bundledAudio.name, withExtension: bundledAudio.extension) else {
            AudioServicesPlaySystemSound(tone.systemSoundID)
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.volume = 1
            player?.numberOfLoops = 0
            player?.prepareToPlay()
            player?.play()
        } catch {
            AudioServicesPlaySystemSound(tone.systemSoundID)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

private enum GlacialFont {
    static let familyName = "Glacial Indifference"

    static func register() {
        guard let url = Bundle.main.url(forResource: "GlacialIndifference-Regular", withExtension: "woff2") else {
            return
        }

        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func heading(size: CGFloat = 24) -> Font {
        custom(size, .semibold)
    }

    static func custom(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(familyName, size: size)
            .weight(weight)
    }

    static func largeTitle(_ weight: Font.Weight = .regular) -> Font {
        custom(34, weight)
    }

    static func title3(_ weight: Font.Weight = .regular) -> Font {
        custom(20, weight)
    }

    static func headline(_ weight: Font.Weight = .regular) -> Font {
        custom(17, weight)
    }

    static func body(_ weight: Font.Weight = .regular) -> Font {
        custom(17, weight)
    }

    static func callout(_ weight: Font.Weight = .regular) -> Font {
        custom(16, weight)
    }

    static func subheadline(_ weight: Font.Weight = .regular) -> Font {
        custom(15, weight)
    }

    static func footnote(_ weight: Font.Weight = .regular) -> Font {
        custom(13, weight)
    }

    static func caption(_ weight: Font.Weight = .regular) -> Font {
        custom(12, weight)
    }

    static func caption2(_ weight: Font.Weight = .regular) -> Font {
        custom(11, weight)
    }
}

private struct HeaderView: View {
    let activeCount: Int
    let readyCount: Int
    let oldestMinutes: Int?
    let isConnected: Bool
    let section: AppSection

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image("EmberOSLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 265, height: 82)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("EmberOS")

            Spacer()

            HStack(spacing: 14) {
                Image("EmberOSMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(activeCount)")
                        .font(GlacialFont.custom(42, .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(statusText)
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(section == .kitchen && readyCount > 0 ? AppPalette.green : AppPalette.orange)
                    ConnectionDot(isConnected: isConnected)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var oldestText: String {
        guard let oldestMinutes else { return "waiting" }
        return oldestMinutes <= 1 ? "just in" : "oldest \(oldestMinutes)m"
    }

    private var statusText: String {
        switch section {
        case .kitchen:
            return readyCount > 0 ? "\(readyCount) ready" : oldestText
        case .pos:
            return "\(readyCount) categories"
        }
    }
}

private struct ConnectionDot: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? AppPalette.green : AppPalette.red)
                .frame(width: 7, height: 7)
            Text(isConnected ? "LIVE" : "OFFLINE")
                .font(GlacialFont.caption2(.bold))
                .foregroundStyle(AppPalette.muted)
        }
    }
}

private struct MetricsStrip: View {
    let summary: KitchenSummary

    var body: some View {
        HStack(spacing: 12) {
            MetricCard(title: "Pending", value: "\(summary.pending)", icon: "bell.badge", tint: AppPalette.orange)
            MetricCard(title: "Preparing", value: "\(summary.preparing)", icon: "flame.fill", tint: AppPalette.red)
            MetricCard(title: "Ready", value: "\(summary.ready)", icon: "checkmark.seal.fill", tint: AppPalette.green)
            MetricCard(title: "Held", value: "\(summary.held)", icon: "pause.fill", tint: AppPalette.blue)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.10))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(GlacialFont.custom(32, .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(title)
                    .font(GlacialFont.caption2(.bold))
                    .foregroundStyle(AppPalette.muted)
                    .textCase(.uppercase)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .padding(14)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line, lineWidth: 1)
        )
    }
}

private struct FilterBar: View {
    @Binding var selectedSource: KitchenSource?
    @Binding var selectedStatus: KitchenStatus?
    let sources: [KitchenSource]
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "active", isSelected: selectedStatus == nil, namespace: namespace) {
                        selectStatus(nil)
                    }
                    ForEach(KitchenStatus.activeFilters) { status in
                        FilterChip(title: status.label.lowercased(), isSelected: selectedStatus == status, namespace: namespace) {
                            selectStatus(status)
                        }
                    }
                }
                .padding(3)
                .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func selectStatus(_ status: KitchenStatus?) {
        guard selectedStatus != status else { return }
        Haptics.selectionChanged()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.05)) {
            selectedStatus = status
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(GlacialFont.footnote(.semibold))
                .foregroundStyle(isSelected ? .white : AppPalette.ink)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(AppPalette.orange)
                            .matchedGeometryEffect(id: "filter-selection", in: namespace)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppPalette.red)
            Text(message)
                .font(GlacialFont.footnote(.medium))
                .foregroundStyle(AppPalette.ink)
            Spacer()
            Button("Retry", action: retry)
                .font(GlacialFont.footnote(.bold))
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum KitchenGrid {
    static let threeColumns = Array(
        repeating: GridItem(.flexible(minimum: 210), spacing: 12, alignment: .top),
        count: 3
    )
}

private struct SourceArtwork: View {
    let source: KitchenSource
    let status: KitchenStatus

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [source.tint.opacity(0.18), source.tint.opacity(0.06), AppPalette.card],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            SourcePattern(source: source)
                .stroke(source.tint.opacity(0.16), lineWidth: 2)
                .padding(12)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(source.shortLabel)
                        .font(GlacialFont.caption2(.heavy))
                        .tracking(2)
                        .foregroundStyle(source.tint)
                    Text(source.artTitle)
                        .font(GlacialFont.custom(22, .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(.white.opacity(0.92))
                        .frame(width: 62, height: 62)
                        .shadow(color: source.tint.opacity(0.12), radius: 8, y: 4)
                    Image(systemName: source.heroIcon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(source.tint)
                }
            }
            .padding(14)

            VStack {
                HStack {
                    Spacer()
                    Circle()
                        .fill(status.tint)
                        .frame(width: 10, height: 10)
                        .padding(12)
                }
                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(source.tint.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct SourcePattern: Shape {
    let source: KitchenSource

    func path(in rect: CGRect) -> Path {
        var path = Path()

        switch source {
        case .store:
            let shelfY = rect.midY - 10
            path.move(to: CGPoint(x: rect.minX + 12, y: shelfY))
            path.addLine(to: CGPoint(x: rect.maxX - 12, y: shelfY))
            path.move(to: CGPoint(x: rect.minX + 26, y: shelfY - 18))
            path.addLine(to: CGPoint(x: rect.minX + 26, y: shelfY + 30))
            path.move(to: CGPoint(x: rect.midX, y: shelfY - 22))
            path.addLine(to: CGPoint(x: rect.midX, y: shelfY + 30))
            path.addRoundedRect(in: CGRect(x: rect.maxX - 52, y: shelfY - 28, width: 30, height: 44), cornerSize: CGSize(width: 8, height: 8))
        case .website:
            path.addEllipse(in: CGRect(x: rect.midX - 44, y: rect.midY - 42, width: 88, height: 84))
            path.move(to: CGPoint(x: rect.midX - 44, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX + 44, y: rect.midY))
            path.move(to: CGPoint(x: rect.midX, y: rect.midY - 42))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 42))
            path.addEllipse(in: CGRect(x: rect.midX - 20, y: rect.midY - 42, width: 40, height: 84))
        case .grab:
            path.addRoundedRect(in: CGRect(x: rect.minX + 20, y: rect.midY - 18, width: 86, height: 36), cornerSize: CGSize(width: 18, height: 18))
            path.addEllipse(in: CGRect(x: rect.minX + 30, y: rect.midY + 12, width: 22, height: 22))
            path.addEllipse(in: CGRect(x: rect.minX + 82, y: rect.midY + 12, width: 22, height: 22))
            path.move(to: CGPoint(x: rect.minX + 98, y: rect.midY - 12))
            path.addLine(to: CGPoint(x: rect.maxX - 22, y: rect.midY - 34))
        case .shopee:
            path.addRoundedRect(in: CGRect(x: rect.midX - 42, y: rect.midY - 32, width: 84, height: 66), cornerSize: CGSize(width: 10, height: 10))
            path.move(to: CGPoint(x: rect.midX - 24, y: rect.midY - 32))
            path.addQuadCurve(to: CGPoint(x: rect.midX + 24, y: rect.midY - 32), control: CGPoint(x: rect.midX, y: rect.midY - 60))
            path.move(to: CGPoint(x: rect.midX - 18, y: rect.midY - 4))
            path.addLine(to: CGPoint(x: rect.midX + 18, y: rect.midY - 4))
            path.move(to: CGPoint(x: rect.midX - 18, y: rect.midY + 14))
            path.addLine(to: CGPoint(x: rect.midX + 18, y: rect.midY + 14))
        }

        return path
    }
}

private struct OnlineOrderReviewSection: View {
    let orders: [KitchenOnlineOrder]
    let onAccept: (KitchenOnlineOrder) -> Void
    let onDecline: (KitchenOnlineOrder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Orders")
                    .font(GlacialFont.heading())
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Text("\(orders.count) waiting")
                    .font(GlacialFont.footnote(.semibold))
                    .foregroundStyle(orders.isEmpty ? AppPalette.muted : AppPalette.orange)
            }

            if orders.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(AppPalette.green)
                    Text("No online orders waiting for review.")
                        .font(GlacialFont.subheadline(.medium))
                        .foregroundStyle(AppPalette.muted)
                    Spacer()
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVGrid(columns: KitchenGrid.threeColumns, spacing: 12) {
                    ForEach(orders, id: \.id) { order in
                        OnlineOrderCard(
                            order: order,
                            onAccept: { onAccept(order) },
                            onDecline: { onDecline(order) }
                        )
                    }
                }
            }
        }
    }
}

private struct OnlineOrderCard: View {
    let order: KitchenOnlineOrder
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceArtwork(source: .website, status: .pending)
                .frame(height: 108)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(order.orderNumber)
                        .font(GlacialFont.title3(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Spacer(minLength: 6)
                    Text(order.elapsedText)
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(AppPalette.orange)
                }

                Text(order.customerDisplay)
                    .font(GlacialFont.subheadline(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(order.items.prefix(3), id: \.id) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.quantity)x")
                            .font(GlacialFont.caption(.bold))
                            .foregroundStyle(AppPalette.orange)
                            .frame(width: 30, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.productName)
                                .font(GlacialFont.subheadline(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            if !item.toppings.isEmpty {
                                Text(item.toppings.compactMap(\.name).joined(separator: ", "))
                                    .font(GlacialFont.caption(.medium))
                                    .foregroundStyle(AppPalette.muted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(minHeight: 72, alignment: .top)

            if let notes = order.notes, !notes.isEmpty {
                Text(notes)
                    .font(GlacialFont.caption(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack {
                Label("website", systemImage: "globe")
                Spacer()
                Text(order.totalText)
                    .font(GlacialFont.caption(.bold))
            }
            .font(GlacialFont.caption(.semibold))
            .foregroundStyle(AppPalette.muted)

            if order.status == .submitted {
                HStack(spacing: 10) {
                    Button(action: onDecline) {
                        Text("Decline")
                            .font(GlacialFont.caption(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.ink)
                    .background(AppPalette.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    Button(action: onAccept) {
                        Text("Accept")
                            .font(GlacialFont.caption(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                HStack(spacing: 10) {
                    Text("Accepted. Waiting for prep.")
                        .font(GlacialFont.caption2(.semibold))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: onDecline) {
                        Label("Cancel", systemImage: "trash")
                            .font(GlacialFont.caption(.bold))
                            .frame(height: 34)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.red)
                    .background(AppPalette.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line, lineWidth: 1)
        )
    }
}

private struct QueueSection: View {
    let orders: [KitchenOrder]
    let isInitialLoading: Bool
    let isRefreshing: Bool
    let onSelect: (KitchenOrder) -> Void
    let onStatus: (KitchenOrder, KitchenStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Queue")
                    .font(GlacialFont.heading())
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(AppPalette.orange)
                    }

                    Text(isInitialLoading && orders.isEmpty ? "loading" : "\(orders.count) tickets")
                        .font(GlacialFont.footnote(.semibold))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            if orders.isEmpty && isInitialLoading {
                InitialLoadingView()
            } else if orders.isEmpty {
                EmptyKitchenView()
            } else {
                LazyVGrid(columns: KitchenGrid.threeColumns, spacing: 12) {
                    ForEach(orders, id: \.id) { order in
                        OrderCard(order: order, onSelect: { onSelect(order) }, onStatus: { onStatus(order, $0) })
                    }
                }
            }
        }
    }
}

private struct InitialLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(AppPalette.orange)
            Text("Loading kitchen rail")
                .font(GlacialFont.headline(.semibold))
                .foregroundStyle(AppPalette.ink)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyKitchenView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(AppPalette.green)
            Text("No active orders")
                .font(GlacialFont.title3(.semibold))
            Text("The rail is clean. New Store, Website, Grab, and Shopee orders will appear here.")
                .font(GlacialFont.subheadline())
                .foregroundStyle(AppPalette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct POSDashboardView: View {
    @ObservedObject var store: POSStore
    let baseURL: String
    let token: String
    @State private var selectedCategory: String?
    @State private var selectedProduct: POSProduct?
    @State private var isCheckoutOpen = false
    @State private var isStartShiftOpen = false
    @State private var cashMovementType: POSCashMovementType?
    @State private var isEndShiftOpen = false

    private var categories: [POSCategory] {
        store.bootstrap?.catalog.categories ?? []
    }

    private var products: [POSProduct] {
        guard let selectedCategory else {
            return store.bootstrap?.catalog.products ?? []
        }

        return store.bootstrap?.catalog.products.filter { $0.category == selectedCategory } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = store.errorMessage {
                ErrorBanner(message: message) {
                    Task { await store.refresh(baseURL: baseURL, token: token) }
                }
            }

            if let message = store.saleMessage {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppPalette.green)
                    Text(message)
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.green.opacity(0.24), lineWidth: 1)
                )
            }

            if store.isInitialLoading {
                InitialLoadingView()
            } else if let bootstrap = store.bootstrap {
                POSShiftCard(
                    operator: bootstrap.operator,
                    shift: bootstrap.shift,
                    isSubmitting: store.isShiftSubmitting,
                    onOpenShift: { isStartShiftOpen = true },
                    onCashIn: { cashMovementType = .deposit },
                    onCashOut: { cashMovementType = .withdrawal },
                    onCloseShift: { isEndShiftOpen = true }
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Orders")
                                .font(GlacialFont.custom(42, .semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text("Queue")
                                .font(GlacialFont.custom(30, .regular))
                                .foregroundStyle(AppPalette.orange)
                        }

                        Spacer()

                        if store.isRefreshing {
                            ProgressView()
                                .tint(AppPalette.orange)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            POSCategoryChip(title: "all", isSelected: selectedCategory == nil) {
                                withAnimation(.snappy(duration: 0.22)) {
                                    selectedCategory = nil
                                }
                            }

                            ForEach(categories) { category in
                                POSCategoryChip(
                                    title: category.name.lowercased(),
                                    isSelected: selectedCategory == category.name
                                ) {
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedCategory = category.name
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))

                HStack(alignment: .top, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                        ForEach(products) { product in
                            POSProductCard(
                                product: product,
                                quantityInCart: store.quantityInCart(for: product)
                            ) {
                                selectedProduct = product
                            }
                        }
                    }

                    POSCartPanel(
                        lines: store.cartLines,
                        total: store.cartTotal,
                        onIncrement: store.increment(line:),
                        onDecrement: store.decrement(line:),
                        onClear: store.clearCart,
                        onCheckout: { isCheckoutOpen = true }
                    )
                    .frame(width: 300)
                }
            } else {
                EmptyKitchenView()
            }
        }
        .sheet(item: $selectedProduct) { product in
            POSProductSheet(product: product) { toppings in
                store.add(product: product, toppings: toppings)
                selectedProduct = nil
            }
        }
        .sheet(isPresented: $isCheckoutOpen) {
            POSCheckoutSheet(
                lines: store.cartLines,
                total: store.cartTotal,
                baseURL: baseURL,
                token: token,
                isSubmitting: store.isSubmitting,
                submit: { paymentMethod, source, reference, customer, discountPercent, notes in
                    await store.submitSale(
                        baseURL: baseURL,
                        token: token,
                        paymentMethod: paymentMethod,
                        orderSource: source,
                        externalReference: reference,
                        customer: customer,
                        discountPercent: discountPercent,
                        notes: notes
                    )
                }
            )
        }
        .sheet(isPresented: $isStartShiftOpen) {
            POSStartShiftSheet(isSubmitting: store.isShiftSubmitting) { openingCash, notes in
                await store.startShift(baseURL: baseURL, token: token, openingCash: openingCash, notes: notes)
            }
        }
        .sheet(item: $cashMovementType) { type in
            POSCashMovementSheet(type: type, isSubmitting: store.isShiftSubmitting) { amount, reason in
                await store.recordCashMovement(baseURL: baseURL, token: token, type: type, amount: amount, reason: reason)
            }
        }
        .sheet(isPresented: $isEndShiftOpen) {
            POSEndShiftSheet(
                expectedCash: store.bootstrap?.shift.recap?.expectedCash,
                isSubmitting: store.isShiftSubmitting
            ) { closingCash, notes in
                await store.endShift(baseURL: baseURL, token: token, closingCash: closingCash, notes: notes)
            }
        }
    }
}

private struct POSShiftCard: View {
    let `operator`: POSOperator
    let shift: POSShiftEnvelope
    let isSubmitting: Bool
    let onOpenShift: () -> Void
    let onCashIn: () -> Void
    let onCashOut: () -> Void
    let onCloseShift: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("POS")
                    .font(GlacialFont.caption(.bold))
                    .tracking(2)
                    .foregroundStyle(AppPalette.orange)
                Text(shift.isOpen ? "Shift open" : "Shift closed")
                    .font(GlacialFont.title3(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("Operator \(`operator`.name)")
                    .font(GlacialFont.footnote())
                    .foregroundStyle(AppPalette.muted)

                if let activeShift = shift.shift {
                    Text("Shift #\(activeShift.id)")
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Text(shift.isOpen ? "ready" : "open shift")
                    .font(GlacialFont.caption(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(shift.isOpen ? AppPalette.green : AppPalette.orange)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))

                if let recap = shift.recap {
                    Text("\(Int(recap.revenue).formatted()) VND")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("\(recap.orders) orders")
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                }

                HStack(spacing: 8) {
                    if shift.isOpen {
                        POSMiniButton(title: "cash in", isLoading: isSubmitting, action: onCashIn)
                        POSMiniButton(title: "cash out", isLoading: isSubmitting, action: onCashOut)
                        POSMiniButton(title: "close", isLoading: isSubmitting, tone: .danger, action: onCloseShift)
                    } else {
                        POSMiniButton(title: "open shift", isLoading: isSubmitting, action: onOpenShift)
                    }
                }
            }
        }
        .padding(18)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct POSMiniButton: View {
    enum Tone {
        case normal
        case danger
    }

    let title: String
    let isLoading: Bool
    var tone: Tone = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(GlacialFont.caption(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(tone == .danger ? AppPalette.red : AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.65 : 1)
    }
}

private struct POSStartShiftSheet: View {
    let isSubmitting: Bool
    let submit: (Double, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var openingCash = ""
    @State private var notes = ""

    var body: some View {
        POSShiftFormShell(
            title: "Open shift",
            primaryLabel: "open shift",
            isSubmitting: isSubmitting,
            canSubmit: parsedOpeningCash != nil,
            submit: {
                guard let amount = parsedOpeningCash else { return false }
                return await submit(amount, notes)
            }
        ) {
            POSMoneyField(title: "opening cash", placeholder: "500000", text: $openingCash)
            POSNotesField(title: "notes", placeholder: "Optional", text: $notes)
        }
    }

    private var parsedOpeningCash: Double? {
        POSMoneyParser.value(openingCash)
    }
}

private struct POSCashMovementSheet: View {
    let type: POSCashMovementType
    let isSubmitting: Bool
    let submit: (Double, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var reason = ""

    var body: some View {
        POSShiftFormShell(
            title: type.title,
            primaryLabel: type.buttonLabel,
            isSubmitting: isSubmitting,
            canSubmit: parsedAmount != nil && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            submit: {
                guard let parsedAmount else { return false }
                return await submit(parsedAmount, reason)
            }
        ) {
            POSMoneyField(title: "amount", placeholder: "100000", text: $amount)
            POSNotesField(title: "reason", placeholder: type.reasonPlaceholder, text: $reason)
        }
    }

    private var parsedAmount: Double? {
        guard let value = POSMoneyParser.value(amount), value > 0 else {
            return nil
        }

        return value
    }
}

private struct POSEndShiftSheet: View {
    let expectedCash: Double?
    let isSubmitting: Bool
    let submit: (Double?, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var closingCash = ""
    @State private var notes = ""

    var body: some View {
        POSShiftFormShell(
            title: "Close shift",
            primaryLabel: "close shift",
            isSubmitting: isSubmitting,
            canSubmit: closingCash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedClosingCash != nil,
            submit: {
                await submit(parsedClosingCash, notes)
            }
        ) {
            if let expectedCash {
                HStack {
                    Text("expected cash")
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.muted)
                    Spacer()
                    Text("\(Int(expectedCash).formatted()) VND")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                }
                .padding(14)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
            }

            POSMoneyField(title: "closing cash", placeholder: "Optional", text: $closingCash)
            POSNotesField(title: "notes", placeholder: "Optional", text: $notes)
        }
    }

    private var parsedClosingCash: Double? {
        POSMoneyParser.value(closingCash)
    }
}

private struct POSShiftFormShell<Content: View>: View {
    let title: String
    let primaryLabel: String
    let isSubmitting: Bool
    let canSubmit: Bool
    let submit: () async -> Bool
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    content
                    Spacer(minLength: 0)
                }
                .padding(20)

                VStack(spacing: 12) {
                    Divider()
                    Button {
                        Task {
                            if await submit() {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isSubmitting ? "saving" : primaryLabel)
                                .font(GlacialFont.caption(.bold))
                                .tracking(2.2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting || !canSubmit)
                    .opacity(isSubmitting || !canSubmit ? 0.55 : 1)
                }
                .padding(20)
                .background(.white)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(AppPalette.ink)
                }
            }
        }
    }
}

private struct POSMoneyField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(GlacialFont.caption(.bold))
                .tracking(1.8)
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: $text)
                .font(GlacialFont.custom(28, .semibold))
                .keyboardType(.numberPad)
                .padding(14)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct POSNotesField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(GlacialFont.caption(.bold))
                .tracking(1.8)
                .foregroundStyle(AppPalette.muted)
            TextField(placeholder, text: $text, axis: .vertical)
                .font(GlacialFont.subheadline())
                .lineLimit(2...4)
                .padding(14)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private enum POSMoneyParser {
    static func value(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty, let value = Double(normalized), value >= 0 else {
            return nil
        }

        return value
    }
}

private extension String {
    var emptyAsNil: String? {
        isEmpty ? nil : self
    }
}

private struct POSCategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(GlacialFont.caption(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(isSelected ? .white : AppPalette.ink)
                .background(isSelected ? AppPalette.red : AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct POSProductCard: View {
    let product: POSProduct
    let quantityInCart: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    AsyncImage(url: product.imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Image(systemName: "fork.knife")
                                .font(.title2)
                                .foregroundStyle(AppPalette.orange)
                        case .empty:
                            ProgressView()
                                .tint(AppPalette.orange)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: 66, height: 66)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(product.name.uppercased())
                            .font(GlacialFont.headline(.semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                        Text(product.category)
                            .font(GlacialFont.caption())
                            .foregroundStyle(AppPalette.muted)
                    }

                    Spacer()

                    if quantityInCart > 0 {
                        Text("\(quantityInCart)")
                            .font(GlacialFont.caption(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(AppPalette.orange, in: Circle())
                    }
                }

                HStack {
                    Text("\(Int(product.price).formatted()) VND")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.orange)

                    Spacer()

                    Text("\(Int(product.currentStock).formatted()) \(product.unit)")
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(product.currentStock > 0 ? AppPalette.green : AppPalette.red)
                }

                Divider()

                HStack {
                    Label("\(product.toppings.count) toppings", systemImage: "plus.square")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(GlacialFont.caption())
                .foregroundStyle(AppPalette.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(quantityInCart > 0 ? AppPalette.orange.opacity(0.8) : AppPalette.line.opacity(0.8), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct POSProductSheet: View {
    let product: POSProduct
    let onAdd: ([POSTopping]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedToppingIDs = Set<Int>()

    private var selectedToppings: [POSTopping] {
        product.toppings.filter { selectedToppingIDs.contains($0.id) }
    }

    private var total: Double {
        product.price + selectedToppings.reduce(0) { $0 + $1.price }
    }

    private var toppingGroups: [(String, [POSTopping])] {
        Dictionary(grouping: product.toppings, by: \.category)
            .map { category, toppings in
                (
                    category,
                    toppings.sorted {
                        $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder
                    }
                )
            }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    productHeader

                    if toppingGroups.isEmpty {
                        Text("No toppings for this product.")
                            .font(GlacialFont.subheadline())
                            .foregroundStyle(AppPalette.muted)
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        ForEach(toppingGroups, id: \.0) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.0.uppercased())
                                    .font(GlacialFont.caption(.bold))
                                    .tracking(1.8)
                                    .foregroundStyle(AppPalette.orange)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                                    ForEach(group.1) { topping in
                                        POSToppingOption(
                                            topping: topping,
                                            isSelected: selectedToppingIDs.contains(topping.id)
                                        ) {
                                            toggle(topping)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(AppPalette.line.opacity(0.8), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(AppPalette.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(Int(total).formatted()) VND")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.orange)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onAdd(selectedToppings)
                } label: {
                    Text("Add to cart")
                        .font(GlacialFont.caption(.bold))
                        .tracking(2.4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(20)
                .background(.white)
            }
        }
    }

    private var productHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: product.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Image(systemName: "fork.knife")
                        .font(.largeTitle)
                        .foregroundStyle(AppPalette.orange)
                case .empty:
                    ProgressView()
                        .tint(AppPalette.orange)
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 130, height: 130)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(product.category.uppercased())
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.6)
                    .foregroundStyle(AppPalette.orange)
                Text(product.name.uppercased())
                    .font(GlacialFont.custom(32, .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                Text("\(Int(product.price).formatted()) VND")
                    .font(GlacialFont.title3(.semibold))
                    .foregroundStyle(AppPalette.orange)
                if let description = product.description, !description.isEmpty {
                    Text(description)
                        .font(GlacialFont.subheadline())
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(3)
                }
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.8), lineWidth: 1)
        )
    }

    private func toggle(_ topping: POSTopping) {
        if selectedToppingIDs.contains(topping.id) {
            selectedToppingIDs.remove(topping.id)
        } else {
            selectedToppingIDs.insert(topping.id)
        }

        Haptics.impact(.light)
    }
}

private struct POSToppingOption: View {
    let topping: POSTopping
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(topping.name)
                        .font(GlacialFont.subheadline(.semibold))
                        .lineLimit(1)
                    Text("+\(Int(topping.price).formatted()) VND")
                        .font(GlacialFont.caption(.bold))
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(isSelected ? .white : AppPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(isSelected ? AppPalette.orange : AppPalette.card, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

private struct POSCartPanel: View {
    let lines: [POSCartLine]
    let total: Double
    let onIncrement: (POSCartLine) -> Void
    let onDecrement: (POSCartLine) -> Void
    let onClear: () -> Void
    let onCheckout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("cart")
                        .font(GlacialFont.caption(.bold))
                        .tracking(2)
                        .foregroundStyle(AppPalette.orange)
                    Text("\(lines.reduce(0) { $0 + $1.quantity }) items")
                        .font(GlacialFont.title3(.semibold))
                        .foregroundStyle(AppPalette.ink)
                }

                Spacer()

                if !lines.isEmpty {
                    Button("clear", action: onClear)
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(AppPalette.red)
                }
            }

            if lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "basket")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(AppPalette.orange)
                    Text("Tap a product to start a local POS cart.")
                        .font(GlacialFont.subheadline())
                        .foregroundStyle(AppPalette.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 10) {
                    ForEach(lines) { line in
                        POSCartLineRow(
                            line: line,
                            onIncrement: { onIncrement(line) },
                            onDecrement: { onDecrement(line) }
                        )
                    }
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text("total")
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.muted)
                    Spacer()
                    Text("\(Int(total).formatted()) VND")
                        .font(GlacialFont.title3(.semibold))
                        .foregroundStyle(AppPalette.ink)
                }

                Button(action: onCheckout) {
                    Text("checkout")
                        .font(GlacialFont.caption(.bold))
                        .tracking(2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(.white)
                        .background(AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.8), lineWidth: 1)
        )
    }
}

private struct POSCartLineRow: View {
    let line: POSCartLine
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.product.name)
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)

                    if line.toppings.isEmpty {
                        Text("no toppings")
                            .font(GlacialFont.caption())
                            .foregroundStyle(AppPalette.muted)
                    } else {
                        Text(line.toppings.map(\.name).joined(separator: ", "))
                            .font(GlacialFont.caption())
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Text("\(Int(line.lineTotal).formatted())")
                    .font(GlacialFont.caption(.bold))
                    .foregroundStyle(AppPalette.orange)
            }

            HStack(spacing: 12) {
                Button(action: onDecrement) {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                }

                Text("\(line.quantity)")
                    .font(GlacialFont.subheadline(.semibold))
                    .frame(minWidth: 20)

                Button(action: onIncrement) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                }

                Spacer()
            }
            .foregroundStyle(AppPalette.ink)
        }
        .padding(12)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct POSCheckoutSheet: View {
    let lines: [POSCartLine]
    let total: Double
    let baseURL: String
    let token: String
    let isSubmitting: Bool
    let submit: (POSPaymentMethod, POSOrderSource, String, POSCustomer?, Double, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var paymentMethod: POSPaymentMethod = .cash
    @State private var orderSource: POSOrderSource = .inStore
    @State private var externalReference = ""
    @State private var discountPercent = ""
    @State private var notes = ""
    @State private var selectedCustomer: POSCustomer?
    @State private var customerSearch = ""
    @State private var customerResults: [POSCustomer] = []
    @State private var customerError: String?
    @State private var isSearchingCustomer = false
    @State private var isCreatingCustomer = false
    @State private var isCreateCustomerOpen = false
    @State private var newCustomerName = ""
    @State private var newCustomerPhone = ""
    @State private var newCustomerEmail = ""

    private var parsedDiscountPercent: Double {
        let normalized = discountPercent
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Double(normalized) ?? 0
        return max(0, min(value, 100))
    }

    private var discountAmount: Double {
        total * parsedDiscountPercent / 100
    }

    private var finalTotal: Double {
        max(0, total - discountAmount)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("review")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2)
                                .foregroundStyle(AppPalette.orange)
                            Text("\(lines.reduce(0) { $0 + $1.quantity }) items")
                                .font(GlacialFont.custom(34, .semibold))
                                .foregroundStyle(AppPalette.ink)
                        }

                        customerSection
                        sourceSelector

                        if orderSource != .inStore {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("order reference")
                                    .font(GlacialFont.caption(.bold))
                                    .tracking(1.5)
                                    .foregroundStyle(AppPalette.muted)
                                TextField("Grab / Shopee code", text: $externalReference)
                                    .font(GlacialFont.subheadline())
                                    .textInputAutocapitalization(.characters)
                                    .padding(12)
                                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        paymentSelector
                        discountSection
                        notesSection

                        VStack(spacing: 10) {
                            ForEach(lines) { line in
                                POSCheckoutLine(line: line)
                            }
                        }
                    }
                    .padding(20)
                }

                VStack(spacing: 12) {
                    Divider()
                    VStack(spacing: 6) {
                        POSCheckoutTotalRow(title: "subtotal", value: total)
                        if parsedDiscountPercent > 0 {
                            POSCheckoutTotalRow(title: "discount \(String(format: "%.1f", parsedDiscountPercent))%", value: -discountAmount, tint: AppPalette.orange)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text("TOTAL")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2)
                                .foregroundStyle(AppPalette.muted)
                            Spacer()
                            Text("\(Int(finalTotal).formatted()) VND")
                                .font(GlacialFont.custom(24, .semibold))
                                .foregroundStyle(AppPalette.ink)
                        }
                    }

                    Button {
                        Task {
                            let didSubmit = await submit(
                                paymentMethod,
                                orderSource,
                                externalReference,
                                selectedCustomer,
                                parsedDiscountPercent,
                                notes
                            )
                            if didSubmit {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isSubmitting ? "sending" : "send sale")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2.2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.72 : 1)
                }
                .padding(20)
                .background(.white)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(AppPalette.ink)
                }
            }
            .onChange(of: orderSource) { _, newSource in
                if newSource != .inStore {
                    paymentMethod = .bank
                } else {
                    paymentMethod = .cash
                }
            }
        }
    }

    private var sourceSelector: some View {
        POSCheckoutChoiceGroup(title: "source") {
            HStack(spacing: 10) {
                sourcePill(.inStore)
                sourcePill(.grabfood)
                sourcePill(.shopeefood)
            }
        }
    }

    private var paymentSelector: some View {
        POSCheckoutChoiceGroup(title: "payment") {
            HStack(spacing: 10) {
                if orderSource == .inStore {
                    paymentPill(.cash)
                    paymentPill(.bank)
                    paymentPill(.qr)
                    paymentPill(.card)
                } else {
                    paymentPill(.bank)
                }
            }
        }
    }

    private var customerSection: some View {
        POSCheckoutChoiceGroup(title: "customer") {
            VStack(alignment: .leading, spacing: 12) {
                if let selectedCustomer {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedCustomer.name)
                                .font(GlacialFont.subheadline(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text(selectedCustomer.detailLine)
                                .font(GlacialFont.caption())
                                .foregroundStyle(AppPalette.muted)
                        }
                        Spacer()
                        Button("clear") {
                            self.selectedCustomer = nil
                        }
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(AppPalette.orange)
                    }
                    .padding(12)
                    .background(AppPalette.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    TextField("Name, phone, email", text: $customerSearch)
                        .font(GlacialFont.subheadline())
                        .textInputAutocapitalization(.words)
                        .padding(12)
                        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit {
                            Task { await searchCustomers() }
                        }

                    Button {
                        Task { await searchCustomers() }
                    } label: {
                        if isSearchingCustomer {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .font(GlacialFont.subheadline(.bold))
                    .frame(width: 46, height: 44)
                    .foregroundStyle(.white)
                    .background(AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
                    .buttonStyle(.plain)
                    .disabled(isSearchingCustomer)
                }

                if let customerError {
                    Text(customerError)
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.red)
                }

                if !customerResults.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(customerResults) { customer in
                            POSCustomerResultRow(customer: customer) {
                                selectedCustomer = customer
                                customerResults = []
                                customerSearch = customer.name
                            }
                        }
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        isCreateCustomerOpen.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: isCreateCustomerOpen ? "minus" : "plus")
                        Text(isCreateCustomerOpen ? "hide new customer" : "new customer")
                    }
                    .font(GlacialFont.caption(.bold))
                    .foregroundStyle(AppPalette.orange)
                }
                .buttonStyle(.plain)

                if isCreateCustomerOpen {
                    VStack(spacing: 8) {
                        TextField("Customer name", text: $newCustomerName)
                            .textInputAutocapitalization(.words)
                        TextField("Phone", text: $newCustomerPhone)
                            .keyboardType(.phonePad)
                        TextField("Email optional", text: $newCustomerEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                        Button {
                            Task { await createCustomer() }
                        } label: {
                            HStack {
                                if isCreatingCustomer {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text(isCreatingCustomer ? "creating" : "create and attach")
                            }
                            .font(GlacialFont.caption(.bold))
                            .tracking(1.6)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(AppPalette.ink, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(isCreatingCustomer || newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .font(GlacialFont.subheadline())
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var discountSection: some View {
        POSCheckoutChoiceGroup(title: "discount") {
            HStack(spacing: 10) {
                TextField("0", text: $discountPercent)
                    .font(GlacialFont.subheadline(.semibold))
                    .keyboardType(.decimalPad)
                    .padding(12)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                Text("%")
                    .font(GlacialFont.subheadline(.semibold))
                    .foregroundStyle(AppPalette.muted)
            }
        }
    }

    private var notesSection: some View {
        POSCheckoutChoiceGroup(title: "notes") {
            TextField("Optional order note", text: $notes, axis: .vertical)
                .font(GlacialFont.subheadline())
                .lineLimit(2...4)
                .padding(12)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sourcePill(_ source: POSOrderSource) -> some View {
        POSCheckoutPill(title: source.label, isSelected: orderSource == source) {
            orderSource = source
        }
    }

    private func paymentPill(_ method: POSPaymentMethod) -> some View {
        POSCheckoutPill(title: method.label, isSelected: paymentMethod == method) {
            paymentMethod = method
        }
    }

    @MainActor
    private func searchCustomers() async {
        guard !isSearchingCustomer else { return }

        isSearchingCustomer = true
        customerError = nil

        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token).searchPOSCustomers(search: customerSearch)
            customerResults = response.customers
            if response.customers.isEmpty {
                customerError = "No customer found."
            }
        } catch {
            customerError = error.localizedDescription
        }

        isSearchingCustomer = false
    }

    @MainActor
    private func createCustomer() async {
        guard !isCreatingCustomer else { return }

        let name = newCustomerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            customerError = "Customer name is required."
            return
        }

        isCreatingCustomer = true
        customerError = nil

        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token).createPOSCustomer(
                POSCreateCustomerRequest(
                    name: name,
                    phone: newCustomerPhone.trimmingCharacters(in: .whitespacesAndNewlines).emptyAsNil,
                    email: newCustomerEmail.trimmingCharacters(in: .whitespacesAndNewlines).emptyAsNil
                )
            )
            selectedCustomer = response.customer
            customerSearch = response.customer.name
            customerResults = []
            newCustomerName = ""
            newCustomerPhone = ""
            newCustomerEmail = ""
            isCreateCustomerOpen = false
            Haptics.notification(.success)
        } catch {
            customerError = error.localizedDescription
            Haptics.notification(.error)
        }

        isCreatingCustomer = false
    }
}

private struct POSCustomerResultRow: View {
    let customer: POSCustomer
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(AppPalette.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(customer.name)
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(customer.detailLine)
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                }
                Spacer()
                Text("Level \(customer.level)")
                    .font(GlacialFont.caption(.bold))
                    .foregroundStyle(AppPalette.orange)
            }
            .padding(10)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct POSCheckoutTotalRow: View {
    let title: String
    let value: Double
    var tint: Color = AppPalette.muted

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(GlacialFont.caption(.bold))
                .tracking(1.4)
                .foregroundStyle(AppPalette.muted)
            Spacer()
            Text("\(value < 0 ? "-" : "")\(Int(abs(value)).formatted()) VND")
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct POSCheckoutChoiceGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(GlacialFont.caption(.bold))
                .tracking(1.8)
                .foregroundStyle(AppPalette.muted)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.8), lineWidth: 1)
        )
    }
}

private struct POSCheckoutPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.lowercased())
                .font(GlacialFont.caption(.bold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isSelected ? .white : AppPalette.ink)
                .background(isSelected ? AppPalette.orange : AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct POSCheckoutLine: View {
    let line: POSCartLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(line.quantity)x")
                .font(GlacialFont.caption(.bold))
                .foregroundStyle(AppPalette.orange)
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(line.product.name)
                    .font(GlacialFont.subheadline(.semibold))
                    .foregroundStyle(AppPalette.ink)
                if !line.toppings.isEmpty {
                    Text(line.toppings.map(\.name).joined(separator: ", "))
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text("\(Int(line.lineTotal).formatted())")
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(AppPalette.ink)
        }
        .padding(14)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OrderCard: View {
    let order: KitchenOrder
    let onSelect: () -> Void
    let onStatus: (KitchenStatus) -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var isCancelRevealed = false

    private let revealWidth: CGFloat = 92

    var body: some View {
        ZStack(alignment: .trailing) {
            if order.canCancel {
                Button {
                    resetSwipe()
                    onStatus(.cancelled)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.title3.weight(.semibold))
                        Text("Cancel")
                            .font(GlacialFont.caption2(.bold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .background(AppPalette.red, in: RoundedRectangle(cornerRadius: 8))
            }

            cardContent
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard order.canCancel else { return }
                            let baseOffset = isCancelRevealed ? -revealWidth : 0
                            dragOffset = min(0, max(-revealWidth, baseOffset + value.translation.width))
                        }
                        .onEnded { value in
                            guard order.canCancel else { return }
                            let shouldReveal = dragOffset < -42 || value.predictedEndTranslation.width < -revealWidth

                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                isCancelRevealed = shouldReveal
                                dragOffset = shouldReveal ? -revealWidth : 0
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                resetSwipe()
                onSelect()
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    SourceArtwork(source: order.source, status: order.status)
                        .frame(height: 112)
                    header
                    meta
                    itemPreview
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                ForEach(order.visibleActions) { status in
                    statusButton(status)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 318, alignment: .topLeading)
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(order.status.tint.opacity(0.28), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(order.orderNumber)
                    .font(GlacialFont.title3(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(order.customerDisplay)
                    .font(GlacialFont.subheadline(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
            }

            Spacer()

            if order.canCancel {
                Button {
                    onStatus(.cancelled)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.red)
                        .frame(width: 32, height: 32)
                        .background(AppPalette.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel order")
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusBadge(status: order.status)
                .fixedSize()

            HStack(spacing: 10) {
            Label(order.source.rawValue, systemImage: order.source.icon)
            Label(order.elapsedText, systemImage: "clock")
            Label("\(order.itemCount) items", systemImage: "takeoutbag.and.cup.and.straw")
            }
        }
        .font(GlacialFont.caption(.semibold))
        .foregroundStyle(AppPalette.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }

    private var itemPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(order.items.prefix(3), id: \.id) { item in
                ItemPreviewLine(item: item)
            }
        }
        .frame(minHeight: 70, alignment: .top)
    }

    private func statusButton(_ status: KitchenStatus) -> some View {
        Button {
            resetSwipe()
            onStatus(status)
        } label: {
            Text(status.actionLabel)
                .font(GlacialFont.caption(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(status == .completed ? .white : AppPalette.ink)
        .background(status == .completed ? AppPalette.ink : status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resetSwipe() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            isCancelRevealed = false
            dragOffset = 0
        }
    }
}

private struct ItemPreviewLine: View {
    let item: KitchenItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(item.quantity)x")
                .font(GlacialFont.caption(.bold))
                .foregroundStyle(AppPalette.orange)
                .frame(width: 30, alignment: .leading)
            Text(item.productName)
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private struct OrderDetailView: View {
    let order: KitchenOrder
    let onStatus: (KitchenStatus) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusBadge(status: order.status)
                        Text(order.orderNumber)
                            .font(GlacialFont.largeTitle(.semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text(order.customerDisplay)
                            .font(GlacialFont.title3(.medium))
                            .foregroundStyle(AppPalette.muted)
                    }

                    DetailSummary(order: order)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Items")
                            .font(GlacialFont.headline())
                            .foregroundStyle(AppPalette.ink)

                        ForEach(order.items) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text("\(item.quantity)x")
                                        .font(GlacialFont.headline())
                                        .foregroundStyle(AppPalette.orange)
                                        .frame(width: 44, alignment: .leading)

                                    Text(item.productName)
                                        .font(GlacialFont.body(.semibold))
                                        .foregroundStyle(AppPalette.ink)

                                    Spacer()
                                }

                                if !item.toppings.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(item.toppings) { topping in
                                            Text("+ \(topping.displayName) x \(topping.quantity)")
                                                .font(GlacialFont.caption(.medium))
                                                .foregroundStyle(AppPalette.muted)
                                        }
                                    }
                                    .padding(.leading, 56)
                                }
                            }
                            .padding(12)
                            .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(AppPalette.line, lineWidth: 1)
                            )
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(order.visibleActions) { status in
                            Button {
                                onStatus(status)
                            } label: {
                                Text(status.actionLabel)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                            }
                            .buttonStyle(.plain)
                            .font(GlacialFont.callout(.bold))
                            .foregroundStyle(status == .completed ? .white : AppPalette.ink)
                            .background(status == .completed ? AppPalette.ink : status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(18)
            }
            .background(AppPalette.background)
            .navigationTitle("Ticket")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct DetailSummary: View {
    let order: KitchenOrder

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            SummaryTile(title: "Source", value: order.source.rawValue, icon: order.source.icon)
            SummaryTile(title: "Elapsed", value: order.elapsedText, icon: "clock")
            SummaryTile(title: "Total", value: order.totalText, icon: "banknote")
            SummaryTile(title: "Phone", value: order.customer.phone ?? "None", icon: "phone")
        }
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppPalette.orange)
                .frame(width: 30, height: 30)
                .background(AppPalette.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GlacialFont.caption())
                    .foregroundStyle(AppPalette.muted)
                Text(value)
                    .font(GlacialFont.subheadline(.bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusBadge: View {
    let status: KitchenStatus

    var body: some View {
        Label(status.label, systemImage: status.icon)
            .font(GlacialFont.caption(.bold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsView: View {
    @ObservedObject var store: KitchenStore
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String = ""
    @State private var token: String = ""
    @State private var previewTone: KitchenChimeTone?

    var body: some View {
        NavigationStack {
            Form {
                Section("Ember OS") {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Kitchen token", text: $token)
                        .textInputAutocapitalization(.never)
                }

                Section("Sound") {
                    ForEach(KitchenChimeTone.allCases) { tone in
                        ChimeToneRow(
                            tone: tone,
                            isSaved: tone == store.chimeTone,
                            isPreviewing: tone == previewTone
                        ) {
                            if previewTone == tone, store.chimeTone != tone {
                                store.saveChimeTone(tone)
                            } else {
                                previewTone = tone
                                store.previewChimeTone(tone)
                            }
                        }
                    }

                    Button("Stop Preview") {
                        previewTone = nil
                        store.stopChime()
                    }
                    .foregroundStyle(AppPalette.red)
                }

                Section {
                    Button("Save and Refresh") {
                        store.saveSettings(baseURL: baseURL, token: token)
                        dismiss()
                    }
                    .font(GlacialFont.headline())
                }
            }
            .navigationTitle("Kitchen Settings")
            .onAppear {
                baseURL = store.baseURL
                token = store.kitchenToken
            }
        }
    }
}

private struct ChimeToneRow: View {
    let tone: KitchenChimeTone
    let isSaved: Bool
    let isPreviewing: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tone.label)
                        .font(GlacialFont.body(.semibold))
                        .foregroundStyle(AppPalette.ink)

                    Text(statusLabel)
                        .font(GlacialFont.caption())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSaved {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppPalette.red)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if isPreviewing && !isSaved {
            return "speaker.wave.2.fill"
        }

        return isSaved ? "checkmark.circle.fill" : "music.note"
    }

    private var iconColor: Color {
        if isSaved || isPreviewing {
            return AppPalette.red
        }

        return .secondary
    }

    private var statusLabel: String {
        if isSaved {
            return "selected"
        }

        if isPreviewing {
            return "tap again to select"
        }

        return "tap to preview"
    }
}

struct KitchenOnlineOrdersResponse: Decodable {
    let onlineOrders: [KitchenOnlineOrder]
    let summary: KitchenOnlineSummary

    enum CodingKeys: String, CodingKey {
        case onlineOrders = "online_orders"
        case summary
    }
}

struct KitchenOnlineOrderResponse: Decodable {
    let onlineOrder: KitchenOnlineOrder

    enum CodingKeys: String, CodingKey {
        case onlineOrder = "online_order"
    }
}

struct KitchenAcceptOnlineOrderResponse: Decodable {
    let onlineOrder: KitchenOnlineOrder
    let sale: KitchenOrder
    let alreadyConverted: Bool

    enum CodingKeys: String, CodingKey {
        case onlineOrder = "online_order"
        case sale
        case alreadyConverted = "already_converted"
    }
}

struct KitchenOrdersResponse: Decodable {
    let orders: [KitchenOrder]
    let summary: KitchenSummary
}

struct KitchenOrderResponse: Decodable {
    let order: KitchenOrder
}

struct KitchenStatusRequest: Encodable {
    let status: String
}

struct POSBootstrapResponse: Decodable {
    let `operator`: POSOperator
    let catalog: POSCatalog
    let shift: POSShiftEnvelope
}

struct POSOperator: Decodable, Equatable {
    let id: Int
    let name: String
    let role: String
}

struct POSCatalog: Decodable, Equatable {
    let categories: [POSCategory]
    let products: [POSProduct]
    let paymentMethods: [String]
    let orderSources: [String]

    enum CodingKeys: String, CodingKey {
        case categories
        case products
        case paymentMethods = "payment_methods"
        case orderSources = "order_sources"
    }
}

struct POSCategory: Identifiable, Decodable, Equatable {
    let name: String
    let sortOrder: Int
    let productIDs: [Int]

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case sortOrder = "sort_order"
        case productIDs = "product_ids"
    }
}

struct POSProduct: Identifiable, Decodable, Equatable {
    let id: Int
    let name: String
    let sku: String?
    let price: Double
    let currentStock: Double
    let unit: String
    let category: String
    let inventoryCategory: String?
    let sortOrder: Int
    let description: String?
    let imageURLString: String?
    let toppings: [POSTopping]

    var imageURL: URL? {
        guard let imageURLString, !imageURLString.isEmpty else { return nil }
        return URL(string: imageURLString)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sku
        case price
        case currentStock = "current_stock"
        case unit
        case category
        case inventoryCategory = "inventory_category"
        case sortOrder = "sort_order"
        case description
        case imageURLString = "image_url"
        case toppings
    }
}

struct POSTopping: Identifiable, Decodable, Equatable {
    let id: Int
    let name: String
    let sku: String?
    let price: Double
    let category: String
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sku
        case price
        case category
        case sortOrder = "sort_order"
    }
}

struct POSCartLine: Identifiable, Equatable {
    let id: String
    let product: POSProduct
    let toppings: [POSTopping]
    var quantity: Int

    var unitPrice: Double {
        product.price + toppings.reduce(0) { $0 + $1.price }
    }

    var lineTotal: Double {
        unitPrice * Double(quantity)
    }

    init(product: POSProduct, toppings: [POSTopping], quantity: Int) {
        self.id = Self.makeID(product: product, toppings: toppings)
        self.product = product
        self.toppings = toppings.sorted {
            $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder
        }
        self.quantity = quantity
    }

    static func makeID(product: POSProduct, toppings: [POSTopping]) -> String {
        let toppingKey = toppings.map(\.id).sorted().map(String.init).joined(separator: "-")
        return "\(product.id)|\(toppingKey)"
    }
}

enum POSOrderSource: String, CaseIterable, Identifiable {
    case inStore = "in_store"
    case grabfood
    case shopeefood

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inStore:
            return "Store"
        case .grabfood:
            return "Grab"
        case .shopeefood:
            return "Shopee"
        }
    }
}

enum POSPaymentMethod: String, CaseIterable, Identifiable {
    case cash
    case bank
    case qr
    case card

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cash:
            return "Cash"
        case .bank:
            return "Bank"
        case .qr:
            return "QR"
        case .card:
            return "Card"
        }
    }

    static func available(for source: POSOrderSource) -> [POSPaymentMethod] {
        source == .inStore ? allCases : [.bank]
    }
}

enum POSCashMovementType: String, Identifiable {
    case deposit
    case withdrawal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deposit:
            return "Cash in"
        case .withdrawal:
            return "Cash out"
        }
    }

    var buttonLabel: String {
        switch self {
        case .deposit:
            return "add cash"
        case .withdrawal:
            return "remove cash"
        }
    }

    var reasonPlaceholder: String {
        switch self {
        case .deposit:
            return "Change top up"
        case .withdrawal:
            return "Petty cash"
        }
    }
}

struct POSCreateSaleRequest: Encodable {
    let cart: [POSSaleCartItem]
    let paymentMethod: String
    let orderSource: String
    let externalOrderReference: String?
    let customerID: Int?
    let discountPercent: Double
    let notes: String?
    let checkoutToken: String

    enum CodingKeys: String, CodingKey {
        case cart
        case paymentMethod = "payment_method"
        case orderSource = "order_source"
        case externalOrderReference = "external_order_reference"
        case customerID = "customer_id"
        case discountPercent = "discount_percent"
        case notes
        case checkoutToken = "checkout_token"
    }
}

struct POSSaleCartItem: Encodable {
    let id: Int
    let quantity: Int
    let toppings: [POSSaleTopping]

    init(line: POSCartLine) {
        self.id = line.product.id
        self.quantity = line.quantity
        self.toppings = line.toppings.map { POSSaleTopping(id: $0.id) }
    }
}

struct POSSaleTopping: Encodable {
    let id: Int
}

struct POSCreateSaleResponse: Decodable {
    let message: String
    let saleID: Int
    let alreadyProcessed: Bool

    enum CodingKeys: String, CodingKey {
        case message
        case saleID = "sale_id"
        case alreadyProcessed = "already_processed"
    }
}

struct POSCustomersResponse: Decodable {
    let customers: [POSCustomer]
}

struct POSCustomerResponse: Decodable {
    let customer: POSCustomer
}

struct POSCustomer: Identifiable, Decodable, Equatable {
    let id: Int
    let name: String
    let phone: String?
    let email: String?
    let level: Int
    let xp: Int
    let loyaltyStamps: Int
    let loyaltyTarget: Int
    let rewardCount: Int

    var detailLine: String {
        let contact = [phone, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        let loyalty = "\(loyaltyStamps)/\(loyaltyTarget) stamps"
        return contact.isEmpty ? loyalty : "\(contact) · \(loyalty)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case phone
        case email
        case level
        case xp
        case loyaltyStamps = "loyalty_stamps"
        case loyaltyTarget = "loyalty_target"
        case rewardCount = "reward_count"
    }
}

struct POSCreateCustomerRequest: Encodable {
    let name: String
    let phone: String?
    let email: String?
}

struct POSStartShiftRequest: Encodable {
    let openingCash: Double
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case openingCash = "opening_cash"
        case notes
    }
}

struct POSCashMovementRequest: Encodable {
    let type: String
    let amount: Double
    let reason: String
}

struct POSEndShiftRequest: Encodable {
    let closingCash: Double?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case closingCash = "closing_cash"
        case notes
    }
}

struct POSShiftResponse: Decodable {
    let shift: POSShiftEnvelope
}

struct POSShiftEnvelope: Decodable, Equatable {
    let isOpen: Bool
    let shift: POSShift?
    let recap: POSShiftRecap?

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open"
        case shift
        case recap
    }
}

struct POSShift: Decodable, Equatable {
    let id: Int
    let startedAt: Date?
    let endedAt: Date?
    let openingCash: Double
    let closingCash: Double?
    let status: String?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case openingCash = "opening_cash"
        case closingCash = "closing_cash"
        case status
        case notes
    }
}

struct POSShiftRecap: Decodable, Equatable {
    let orders: Int
    let revenue: Double
    let averageTicket: Double
    let expectedCash: Double
    let cashSales: Double
    let cashDeposited: Double
    let cashWithdrawn: Double

    enum CodingKeys: String, CodingKey {
        case orders
        case revenue
        case averageTicket = "average_ticket"
        case expectedCash = "expected_cash"
        case cashSales = "cash_sales"
        case cashDeposited = "cash_deposited"
        case cashWithdrawn = "cash_withdrawn"
    }
}

struct KitchenOnlineSummary: Decodable {
    let submitted: Int
    let accepted: Int
}

struct KitchenSummary: Decodable {
    let pending: Int
    let preparing: Int
    let ready: Int
    let held: Int

    static let empty = KitchenSummary(pending: 0, preparing: 0, ready: 0, held: 0)
}

struct KitchenOnlineOrder: Identifiable, Decodable, Equatable {
    let id: Int
    let orderNumber: String
    let status: KitchenOnlineOrderStatus
    let fulfillmentMethod: String?
    let paymentMethod: String?
    let paymentStatus: String?
    let createdAt: Date?
    let elapsedMinutes: Int
    let customer: KitchenCustomer
    let notes: String?
    let items: [KitchenOnlineOrderItem]
    let totals: KitchenOnlineTotals

    enum CodingKeys: String, CodingKey {
        case id
        case orderNumber = "order_number"
        case status
        case fulfillmentMethod = "fulfillment_method"
        case paymentMethod = "payment_method"
        case paymentStatus = "payment_status"
        case createdAt = "created_at"
        case elapsedMinutes = "elapsed_minutes"
        case customer
        case notes
        case items
        case totals
    }

    var customerDisplay: String {
        customer.name?.isEmpty == false ? customer.name! : "Guest order"
    }

    var elapsedText: String {
        elapsedMinutes <= 1 ? "just now" : "\(elapsedMinutes)m"
    }

    var totalText: String {
        "\(Int(totals.total).formatted()) VND"
    }

    var itemCount: Int {
        items.reduce(0) { $0 + $1.quantity }
    }
}

struct KitchenOnlineOrderItem: Identifiable, Decodable, Equatable {
    let id: Int
    let productName: String
    let quantity: Int
    let notes: String?
    let toppings: [KitchenOnlineOrderTopping]

    enum CodingKeys: String, CodingKey {
        case id
        case productName = "product_name"
        case quantity
        case notes
        case toppings
    }
}

struct KitchenOnlineOrderTopping: Identifiable, Decodable, Equatable {
    let id: Int
    let name: String?
    let quantity: Int
}

struct KitchenOnlineTotals: Decodable, Equatable {
    let subtotal: Double
    let deliveryFee: Double
    let total: Double

    enum CodingKeys: String, CodingKey {
        case subtotal
        case deliveryFee = "delivery_fee"
        case total
    }
}

enum KitchenOnlineOrderStatus: String, Decodable {
    case submitted
    case accepted
    case rejected
    case cancelled
}

struct KitchenOrder: Identifiable, Decodable, Equatable {
    let id: Int
    let orderNumber: String
    let source: KitchenSource
    let status: KitchenStatus
    let createdAt: Date?
    let elapsedMinutes: Int
    let customer: KitchenCustomer
    let items: [KitchenItem]
    let totals: KitchenTotals?
    let notes: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case orderNumber = "order_number"
        case source
        case status
        case createdAt = "created_at"
        case elapsedMinutes = "elapsed_minutes"
        case customer
        case items
        case totals
        case notes
        case updatedAt = "updated_at"
    }

    var customerDisplay: String {
        customer.name?.isEmpty == false ? customer.name! : "Guest order"
    }

    var itemCount: Int {
        items.reduce(0) { $0 + $1.quantity }
    }

    var elapsedText: String {
        elapsedMinutes <= 1 ? "just now" : "\(elapsedMinutes)m"
    }

    var totalText: String {
        guard let total = totals?.total else { return "-" }
        return "\(Int(total).formatted()) VND"
    }

    var nextActions: [KitchenStatus] {
        switch status {
        case .pending:
            return [.preparing, .held, .cancelled]
        case .preparing:
            return [.ready, .held, .cancelled]
        case .ready:
            return [.completed, .cancelled]
        case .held:
            return [.preparing, .completed, .cancelled]
        case .completed, .cancelled:
            return []
        }
    }

    var visibleActions: [KitchenStatus] {
        nextActions.filter { $0 != .cancelled }
    }

    var canCancel: Bool {
        nextActions.contains(.cancelled)
    }

    var isPastAlertThreshold: Bool {
        elapsedMinutes >= 12 && status != .ready
    }
}

struct KitchenCustomer: Decodable, Equatable {
    let name: String?
    let phone: String?
}

struct KitchenItem: Identifiable, Decodable, Equatable {
    let id: Int
    let productName: String
    let quantity: Int
    let toppings: [KitchenTopping]
    let notes: String?
    let kitchenStatus: KitchenStatus

    enum CodingKeys: String, CodingKey {
        case id
        case productName = "product_name"
        case quantity
        case toppings
        case notes
        case kitchenStatus = "kitchen_status"
    }
}

struct KitchenTopping: Identifiable, Decodable, Equatable {
    let id: Int
    let name: String?
    let quantity: Int

    var displayName: String {
        guard let name, !name.isEmpty else { return "Topping" }
        return name
    }
}

struct KitchenTotals: Decodable, Equatable {
    let subtotal: Double
    let discount: Double
    let deliveryFee: Double
    let total: Double

    enum CodingKeys: String, CodingKey {
        case subtotal
        case discount
        case deliveryFee = "delivery_fee"
        case total
    }
}

enum KitchenSource: String, Decodable, Identifiable {
    case store = "Store"
    case website = "Website"
    case grab = "Grab"
    case shopee = "Shopee"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .store: "storefront"
        case .website: "globe"
        case .grab: "scooter"
        case .shopee: "shippingbox"
        }
    }

    var heroIcon: String {
        switch self {
        case .store: "fork.knife"
        case .website: "globe.asia.australia.fill"
        case .grab: "scooter"
        case .shopee: "bag.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .store: "STORE"
        case .website: "ONLINE"
        case .grab: "GRAB"
        case .shopee: "SHOPEE"
        }
    }

    var artTitle: String {
        switch self {
        case .store: "counter rail"
        case .website: "web order"
        case .grab: "rider pickup"
        case .shopee: "marketplace"
        }
    }

    var tint: Color {
        switch self {
        case .store: AppPalette.orange
        case .website: AppPalette.blue
        case .grab: AppPalette.green
        case .shopee: AppPalette.red
        }
    }
}

enum KitchenStatus: String, Decodable, Identifiable {
    case pending
    case preparing
    case ready
    case completed
    case held
    case cancelled

    var id: String { rawValue }

    static let activeFilters: [KitchenStatus] = [.pending, .preparing, .ready, .held]

    var label: String {
        switch self {
        case .pending: "Pending"
        case .preparing: "Preparing"
        case .ready: "Ready"
        case .completed: "Completed"
        case .held: "Held"
        case .cancelled: "Cancelled"
        }
    }

    var actionLabel: String {
        switch self {
        case .pending: "Pending"
        case .preparing: "Start"
        case .ready: "Ready"
        case .completed: "Done"
        case .held: "Hold"
        case .cancelled: "Cancel"
        }
    }

    var icon: String {
        switch self {
        case .pending: "bell.badge"
        case .preparing: "flame.fill"
        case .ready: "checkmark.seal.fill"
        case .completed: "checkmark.circle.fill"
        case .held: "pause.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: AppPalette.orange
        case .preparing: AppPalette.red
        case .ready: AppPalette.green
        case .completed: AppPalette.ink
        case .held: AppPalette.blue
        case .cancelled: AppPalette.red
        }
    }

    var priority: Int {
        switch self {
        case .ready: 0
        case .pending: 1
        case .preparing: 2
        case .held: 3
        case .completed: 4
        case .cancelled: 5
        }
    }
}

enum KitchenAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(Int, String)
    case serverMessage(Int, String, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Kitchen URL is invalid."
        case .invalidResponse: "Kitchen API response was invalid."
        case .unauthorized: "Kitchen token rejected."
        case .server(let code, let path): "Kitchen API error \(code) at \(path)."
        case .serverMessage(let code, let path, let message): "Kitchen API error \(code) at \(path): \(message)"
        }
    }
}

private extension JSONDecoder {
    static var kitchen: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private enum Haptics {
    static func selectionChanged() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}

private enum AppPalette {
    static let background = Color.white
    static let card = Color(red: 0.975, green: 0.975, blue: 0.970)
    static let line = Color(red: 0.90, green: 0.88, blue: 0.85)
    static let ink = Color(red: 0.14, green: 0.11, blue: 0.09)
    static let muted = Color(red: 0.48, green: 0.44, blue: 0.39)
    static let orange = Color(red: 0.74, green: 0.39, blue: 0.13)
    static let red = Color(red: 0.68, green: 0.22, blue: 0.16)
    static let green = Color(red: 0.13, green: 0.42, blue: 0.18)
    static let blue = Color(red: 0.20, green: 0.36, blue: 0.52)
}

#Preview("Kitchen Dashboard") {
    ContentView(startsPolling: false)
}
