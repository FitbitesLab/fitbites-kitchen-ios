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
import UniformTypeIdentifiers
import PhotosUI

private enum AppSection {
    case kitchen
    case pos
}

struct ContentView: View {
    @StateObject private var store = KitchenStore()
    @StateObject private var posStore = POSStore()
    @Environment(\.scenePhase) private var scenePhase
    private let startsPolling: Bool
    @State private var selectedSection: AppSection = .kitchen
    @State private var selectedStatus: KitchenStatus? = nil
    @State private var selectedSource: KitchenSource? = nil
    @State private var selectedOrder: KitchenOrder?
    @State private var pendingOnlineOrderAction: OnlineOrderAction?
    @State private var pendingKitchenCancelOrder: KitchenOrder?
    @State private var settingsOpen = false
    @State private var isPOSShiftMenuOpen = false
    @State private var isPOSStartShiftOpen = false
    @State private var posCashMovementType: POSCashMovementType?
    @State private var isPOSEndShiftOpen = false
    @State private var isPOSCheckoutOpen = false
    @State private var isPOSRecapOpen = false
    @AppStorage("POSProductDisplayStyle") private var posProductDisplayStyleRaw = POSProductDisplayStyle.productCard.rawValue
    @AppStorage("POSAccentColor") private var posAccentColorRaw = POSAccentColor.ember.rawValue
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
        return store.onlineOrders
    }

    private var showsOnlineOrders: Bool {
        true
    }

    private var selectedPOSAccentColor: POSAccentColor {
        POSAccentColor(rawValue: posAccentColorRaw) ?? .ember
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppPalette.background.ignoresSafeArea()

                if selectedSection == .pos {
                    POSProductAreaWallpaper()
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HeaderView(
                            activeCount: selectedSection == .kitchen ? store.orders.count : posStore.productCount,
                            readyCount: selectedSection == .kitchen ? store.summary.ready : posStore.categoryCount,
                            oldestMinutes: selectedSection == .kitchen ? store.oldestElapsedMinutes : nil,
                            isConnected: selectedSection == .kitchen ? store.isConnected : posStore.isConnected,
                            section: selectedSection,
                            cartItemCount: posStore.cartItemCount,
                            cartTotal: posStore.cartTotal,
                            posAccentColor: selectedPOSAccentColor.color,
                            onCart: { isPOSCheckoutOpen = true }
                        )

                        if selectedSection == .kitchen {
                            MetricsStrip(summary: store.summary, accentColor: selectedPOSAccentColor.color)

                            FilterBar(
                                selectedSource: $selectedSource,
                                selectedStatus: $selectedStatus,
                                sources: store.availableSources,
                                namespace: filterSelectionNamespace,
                                accentColor: selectedPOSAccentColor.color
                            )

                            if let message = store.errorMessage {
                                ErrorBanner(message: message) {
                                    Task { await store.refresh(forceChime: false) }
                                }
                            }

                            if showsOnlineOrders {
                                OnlineOrderReviewSection(
                                    orders: visibleOnlineOrders,
                                    accentColor: selectedPOSAccentColor.color,
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
                                accentColor: selectedPOSAccentColor.color,
                                onSelect: { selectedOrder = $0 },
                                onStatus: { order, status in
                                    handleStatus(order: order, status: status)
                                }
                            )
                        } else {
                            POSDashboardView(
                                store: posStore,
                                baseURL: store.baseURL,
                                token: store.kitchenToken,
                                displayStyle: POSProductDisplayStyle(rawValue: posProductDisplayStyleRaw) ?? .productCard,
                                accentColor: selectedPOSAccentColor.color,
                                isCheckoutOpen: $isPOSCheckoutOpen
                            )
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

                if let message = store.notificationMessage {
                    InAppOrderNotification(message: message, accentColor: selectedPOSAccentColor.color) {
                        selectedSection = .kitchen
                        selectedSource = nil
                        selectedStatus = nil
                        store.notificationMessage = nil
                    }
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
                }

                HStack(spacing: 14) {
                    if selectedSection == .pos, let bootstrap = posStore.bootstrap {
                        POSOperatorButton(
                            operator: bootstrap.operator,
                            shift: bootstrap.shift,
                            isSubmitting: posStore.isShiftSubmitting
                        ) {
                            isPOSShiftMenuOpen = true
                        }
                    }

                    Menu {
                        Button {
                            selectedSection = .kitchen
                            selectedSource = nil
                            selectedStatus = nil
                            Task { await store.refresh(forceChime: false) }
                        } label: {
                            MenuBadgeLabel(
                                title: "Kitchen",
                                systemImage: "house",
                                count: store.waitingOnlineOrderCount,
                                accentColor: selectedPOSAccentColor.color
                            )
                        }

                        Button {
                            selectedSection = .pos
                            Task { await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken) }
                        } label: {
                            Label("POS", systemImage: "cart")
                        }

                        Button {
                            selectedSection = .pos
                            isPOSRecapOpen = true
                            Task { await posStore.refreshRecap(baseURL: store.baseURL, token: store.kitchenToken) }
                        } label: {
                            Label("Recap", systemImage: "chart.bar.xaxis")
                        }

                        Button {
                            settingsOpen = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        TopMenuIcon(badgeCount: store.waitingOnlineOrderCount, accentColor: selectedPOSAccentColor.color)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 18)
                .padding(.trailing, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                if startsPolling {
                    store.start()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard startsPolling else { return }

                if phase == .active {
                    store.start()
                } else if phase == .background {
                    store.stopPolling()
                }
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
                SettingsView(store: store, posStore: posStore)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $isPOSCheckoutOpen) {
                POSCheckoutSheet(
                    lines: posStore.cartLines,
                    total: posStore.cartTotal,
                    baseURL: store.baseURL,
                    token: store.kitchenToken,
                    isSubmitting: posStore.isSubmitting,
                    accentColor: selectedPOSAccentColor.color,
                    productImageURL: { product in
                        posStore.imageURL(for: product)
                    },
                    submit: { paymentMethod, source, reference, customer, discountPercent, notes in
                        await posStore.submitSale(
                            baseURL: store.baseURL,
                            token: store.kitchenToken,
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
            .sheet(isPresented: $isPOSRecapOpen) {
                POSRecapSheet(
                    recap: posStore.recap,
                    isLoading: posStore.isRecapLoading,
                    errorMessage: posStore.recapErrorMessage,
                    accentColor: selectedPOSAccentColor.color
                ) {
                    Task { await posStore.refreshRecap(baseURL: store.baseURL, token: store.kitchenToken) }
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $isPOSShiftMenuOpen) {
                if let bootstrap = posStore.bootstrap {
                    POSShiftControlSheet(
                        operator: bootstrap.operator,
                        shift: bootstrap.shift,
                        isSubmitting: posStore.isShiftSubmitting,
                        accentColor: selectedPOSAccentColor.color,
                        onOpenShift: {
                            isPOSShiftMenuOpen = false
                            isPOSStartShiftOpen = true
                        },
                        onCashIn: {
                            isPOSShiftMenuOpen = false
                            posCashMovementType = .deposit
                        },
                        onCashOut: {
                            isPOSShiftMenuOpen = false
                            posCashMovementType = .withdrawal
                        },
                        onCloseShift: {
                            isPOSShiftMenuOpen = false
                            isPOSEndShiftOpen = true
                        }
                    )
                }
            }
            .sheet(isPresented: $isPOSStartShiftOpen) {
                POSStartShiftSheet(isSubmitting: posStore.isShiftSubmitting, accentColor: selectedPOSAccentColor.color) { openingCash, notes in
                    await posStore.startShift(baseURL: store.baseURL, token: store.kitchenToken, openingCash: openingCash, notes: notes)
                }
            }
            .sheet(item: $posCashMovementType) { type in
                POSCashMovementSheet(type: type, isSubmitting: posStore.isShiftSubmitting, accentColor: selectedPOSAccentColor.color) { amount, reason in
                    await posStore.recordCashMovement(baseURL: store.baseURL, token: store.kitchenToken, type: type, amount: amount, reason: reason)
                }
            }
            .sheet(isPresented: $isPOSEndShiftOpen) {
                POSEndShiftSheet(
                    expectedCash: posStore.bootstrap?.shift.recap?.expectedCash,
                    isSubmitting: posStore.isShiftSubmitting,
                    accentColor: selectedPOSAccentColor.color
                ) { closingCash, notes in
                    await posStore.endShift(baseURL: store.baseURL, token: store.kitchenToken, closingCash: closingCash, notes: notes)
                }
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
    @Published var notificationMessage: String?
    @Published var baseURL = UserDefaults.standard.string(forKey: "KitchenBaseURL") ?? "http://127.0.0.1:8000"
    @Published var kitchenToken = UserDefaults.standard.string(forKey: "KitchenToken") ?? ""
    @Published var chimeTone = KitchenChimeTone(
        rawValue: UserDefaults.standard.string(forKey: "KitchenChimeTone") ?? ""
    ) ?? .fitbites

    private var pollTimer: Timer?
    private var isRefreshInFlight = false
    private var knownOrderIDs = Set<Int>()
    private var knownOnlineOrderIDs = Set<Int>()
    private var alertedOnlineOrderIDs = Set<Int>()
    private var hasLoadedOnce = false
    private var alertingOrderIDs = Set<Int>()
    private var notificationTask: Task<Void, Never>?
    private let chime = KitchenChime()

    var oldestElapsedMinutes: Int? {
        orders.map(\.elapsedMinutes).max()
    }

    var availableSources: [KitchenSource] {
        Array(Set(orders.map(\.source))).sorted { $0.rawValue < $1.rawValue }
    }

    var waitingOnlineOrderCount: Int {
        onlineOrders.filter { $0.status == .submitted }.count
    }

    func start() {
        pollTimer?.invalidate()

        Task { await refresh(forceChime: false) }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh(forceChime: true)
            }
        }

        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func stop() {
        stopPolling()
        isRefreshInFlight = false
        notificationTask?.cancel()
        notificationTask = nil
        chime.stop()
    }

    func saveSettings(baseURL: String, token: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kitchenToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(self.baseURL, forKey: "KitchenBaseURL")
        UserDefaults.standard.set(self.kitchenToken, forKey: "KitchenToken")

        knownOrderIDs.removeAll()
        knownOnlineOrderIDs.removeAll()
        alertedOnlineOrderIDs.removeAll()
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
        guard !isRefreshInFlight else {
            return
        }

        isRefreshInFlight = true
        await performRefresh(forceChime: forceChime)
        isRefreshInFlight = false
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
            let submittedOnlineIDs = Set(
                onlinePayload.onlineOrders
                    .filter { $0.status == .submitted }
                    .map(\.id)
            )
            let previousActiveCount = orders.count + onlineOrders.count
            let newOnlineIDs = incomingOnlineIDs.subtracting(knownOnlineOrderIDs)
            let unalertedSubmittedIDs = submittedOnlineIDs.subtracting(alertedOnlineOrderIDs)
            let alertingIDs = Set(kitchenPayload.orders.filter(\.isPastAlertThreshold).map(\.id))
            let newAlertingIDs = alertingIDs.subtracting(alertingOrderIDs)

            onlineOrders = onlinePayload.onlineOrders
            orders = kitchenPayload.orders
            summary = kitchenPayload.summary
            knownOrderIDs = incomingIDs
            knownOnlineOrderIDs = incomingOnlineIDs
            alertedOnlineOrderIDs.formIntersection(submittedOnlineIDs)
            alertingOrderIDs = alertingIDs
            errorMessage = nil
            isConnected = true
            hasLoadedOnce = true

            if !unalertedSubmittedIDs.isEmpty {
                alertedOnlineOrderIDs.formUnion(unalertedSubmittedIDs)
                showNotification(
                    unalertedSubmittedIDs.count == 1
                        ? "You received a new order!"
                        : "You received \(unalertedSubmittedIDs.count) new orders!"
                )
                chime.play(tone: chimeTone)
            }

            if !firstLoad && (
                !newOnlineIDs.isEmpty ||
                !unalertedSubmittedIDs.isEmpty ||
                previousActiveCount > 0 && onlinePayload.onlineOrders.isEmpty && kitchenPayload.orders.isEmpty ||
                !newAlertingIDs.isEmpty
            ) {
                Haptics.notification(.success)
            }
        } catch {
            if error is CancellationError {
                return
            }

            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }

            errorMessage = error.localizedDescription
            isConnected = false
        }

        isInitialLoading = false
        isRefreshing = false
    }

    private func showNotification(_ message: String) {
        notificationTask?.cancel()
        notificationMessage = message

        notificationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                if self?.notificationMessage == message {
                    self?.notificationMessage = nil
                }
            }
        }
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
            alertedOnlineOrderIDs.remove(order.id)
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
            alertedOnlineOrderIDs.remove(order.id)
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
    @Published var isRecapLoading = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var recapErrorMessage: String?
    @Published var saleMessage: String?
    @Published var recap: POSRecap?
    @Published var productImageOverrideURLs: [Int: URL] = [:]

    private var refreshTask: Task<Void, Never>?
    private let imageOverridesDirectoryName = "POSProductImageOverrides"

    init() {
        loadProductImageOverrides()
    }

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

    func imageURL(for product: POSProduct) -> URL? {
        productImageOverrideURLs[product.id] ?? product.imageURL
    }

    func setProductImageOverride(productID: Int, data: Data) async {
        guard let image = UIImage(data: data),
              let compressedData = image.normalizedForPOSCard().jpegData(compressionQuality: 0.84),
              let directory = productImageOverridesDirectory(createIfNeeded: true) else {
            errorMessage = "This image could not be saved."
            Haptics.notification(.error)
            return
        }

        let fileURL = directory.appendingPathComponent("product-\(productID).jpg")

        do {
            try compressedData.write(to: fileURL, options: [.atomic])
            productImageOverrideURLs[productID] = fileURL
            errorMessage = nil
            Haptics.notification(.success)
        } catch {
            errorMessage = "This image could not be saved."
            Haptics.notification(.error)
        }
    }

    func clearProductImageOverride(productID: Int) {
        guard let fileURL = productImageOverrideURLs[productID] else { return }
        try? FileManager.default.removeItem(at: fileURL)
        productImageOverrideURLs.removeValue(forKey: productID)
        Haptics.impact(.light)
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
            if recap != nil {
                await refreshRecap(baseURL: baseURL, token: token)
            }
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

    func refreshRecap(baseURL: String, token: String) async {
        guard !isRecapLoading else { return }

        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recapErrorMessage = "Add the emberOS Key in Settings."
            return
        }

        isRecapLoading = true
        recapErrorMessage = nil

        do {
            recap = try await KitchenAPIClient(baseURL: baseURL, token: token).fetchPOSRecap().recap
            isConnected = true
        } catch {
            recapErrorMessage = error.localizedDescription
            isConnected = false
        }

        isRecapLoading = false
    }

    private func loadProductImageOverrides() {
        guard let directory = productImageOverridesDirectory(createIfNeeded: false),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        var overrides: [Int: URL] = [:]
        for file in files where file.lastPathComponent.hasPrefix("product-") {
            let idText = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "product-", with: "")
            if let id = Int(idText) {
                overrides[id] = file
            }
        }

        productImageOverrideURLs = overrides
    }

    private func productImageOverridesDirectory(createIfNeeded: Bool) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = documents.appendingPathComponent(imageOverridesDirectoryName, isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory
    }
}

struct KitchenAPIClient {
    let baseURL: String
    let token: String

    func fetchPOSBootstrap() async throws -> POSBootstrapResponse {
        try await request(path: "/api/pos/bootstrap", method: "GET", body: Optional<KitchenStatusRequest>.none)
    }

    func fetchPOSRecap() async throws -> POSRecapResponse {
        try await request(path: "/api/pos/recap", method: "GET", body: Optional<KitchenStatusRequest>.none)
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
    let cartItemCount: Int
    let cartTotal: Double
    let posAccentColor: Color
    let onCart: () -> Void

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

            switch section {
            case .kitchen:
                KitchenHeaderStatus(
                    activeCount: activeCount,
                    readyCount: readyCount,
                    statusText: statusText,
                    isConnected: isConnected,
                    accentColor: posAccentColor
                )
            case .pos:
                POSHeaderCartSummary(
                    itemCount: cartItemCount,
                    total: cartTotal,
                    isConnected: isConnected,
                    accentColor: posAccentColor,
                    onCart: onCart
                )
                .offset(y: 8)
            }
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

private struct TopMenuIcon: View {
    let badgeCount: Int
    let accentColor: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
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

            if badgeCount > 0 {
                Text("\(min(badgeCount, 9))")
                    .font(GlacialFont.caption2(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(accentColor, in: Circle())
                    .offset(x: 4, y: -2)
            }
        }
        .animation(.snappy(duration: 0.18), value: badgeCount)
    }
}

private struct MenuBadgeLabel: View {
    let title: String
    let systemImage: String
    let count: Int
    let accentColor: Color

    var body: some View {
        Label {
            HStack {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(GlacialFont.caption2(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(accentColor, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private struct InAppOrderNotification: View {
    let message: String
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 8))

                Text(message)
                    .font(GlacialFont.subheadline(.semibold))
                    .foregroundStyle(AppPalette.ink)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 420)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(accentColor.opacity(0.28), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
    }
}

private struct KitchenHeaderStatus: View {
    let activeCount: Int
    let readyCount: Int
    let statusText: String
    let isConnected: Bool
    let accentColor: Color

    var body: some View {
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
                    .foregroundStyle(readyCount > 0 ? AppPalette.green : accentColor)
                ConnectionDot(isConnected: isConnected)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct POSHeaderCartSummary: View {
    let itemCount: Int
    let total: Double
    let isConnected: Bool
    let accentColor: Color
    let onCart: () -> Void

    var body: some View {
        Button(action: onCart) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bag")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(accentColor)
                        .frame(width: 45, height: 42)

                    Text("\(itemCount)")
                        .font(GlacialFont.caption2(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(accentColor, in: Circle())
                        .offset(x: 4, y: -1)
                }
                .frame(width: 55, height: 48)

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 5) {
                    Text(cartLabel)
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.7)
                        .foregroundStyle(AppPalette.ink)
                    Text("\(Int(total).formatted()) VND")
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(accentColor)
                    ConnectionDot(isConnected: isConnected)
                }
            }
            .frame(width: 220, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(itemCount == 0)
        .opacity(itemCount == 0 ? 0.72 : 1)
        .accessibilityLabel("POS cart")
    }

    private var cartLabel: String {
        if itemCount == 0 {
            return "CART"
        }

        return itemCount == 1 ? "1 ITEM" : "\(itemCount) ITEMS"
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
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            MetricCard(title: "Pending", value: "\(summary.pending)", icon: "bell.badge", tint: accentColor)
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
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "active", isSelected: selectedStatus == nil, namespace: namespace, accentColor: accentColor) {
                        selectStatus(nil)
                    }
                    ForEach(KitchenStatus.activeFilters) { status in
                        FilterChip(title: status.label.lowercased(), isSelected: selectedStatus == status, namespace: namespace, accentColor: accentColor) {
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
    let accentColor: Color
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
                            .fill(accentColor)
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
    let accentColor: Color
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
                    .foregroundStyle(orders.isEmpty ? AppPalette.muted : accentColor)
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
                            accentColor: accentColor,
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
    let accentColor: Color
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
                        .foregroundStyle(accentColor)
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
                            .foregroundStyle(accentColor)
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
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
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
    let accentColor: Color
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
                            .tint(accentColor)
                    }

                    Text(isInitialLoading && orders.isEmpty ? "loading" : "\(orders.count) tickets")
                        .font(GlacialFont.footnote(.semibold))
                        .foregroundStyle(AppPalette.muted)
                }
            }

            if orders.isEmpty && isInitialLoading {
                InitialLoadingView(accentColor: accentColor)
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
    let accentColor: Color

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(accentColor)
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

private enum POSProductDisplayStyle: String, CaseIterable, Identifiable {
    case productCard
    case grabGrid
    case simpleList

    var id: String { rawValue }

    var label: String {
        switch self {
        case .productCard: "Card"
        case .grabGrid: "Grid"
        case .simpleList: "Row"
        }
    }

    var icon: String {
        switch self {
        case .productCard: "rectangle.portrait.on.rectangle.portrait"
        case .grabGrid: "square.grid.2x2"
        case .simpleList: "list.bullet"
        }
    }
}

private enum POSAccentColor: String, CaseIterable, Identifiable {
    case ember
    case cocoa
    case matcha
    case midnight
    case graphite
    case berry

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ember: "Ember"
        case .cocoa: "Cocoa"
        case .matcha: "Matcha"
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .berry: "Berry"
        }
    }

    var color: Color {
        switch self {
        case .ember: Color(red: 197 / 255, green: 90 / 255, blue: 39 / 255)
        case .cocoa: Color(red: 0.45, green: 0.25, blue: 0.16)
        case .matcha: Color(red: 0.35, green: 0.47, blue: 0.29)
        case .midnight: Color(red: 0.08, green: 0.18, blue: 0.34)
        case .graphite: Color(red: 0.16, green: 0.17, blue: 0.17)
        case .berry: Color(red: 0.54, green: 0.22, blue: 0.30)
        }
    }
}

private enum POSCardSize: String, CaseIterable {
    case small
    case medium
    case big

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .big: "Big"
        }
    }

    var shortLabel: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .big: "L"
        }
    }

    var columnSpan: Int {
        switch self {
        case .small: 1
        case .medium, .big: 2
        }
    }

    var rowSpan: Int {
        switch self {
        case .small, .medium: 1
        case .big: 2
        }
    }

    var next: POSCardSize {
        switch self {
        case .small: .medium
        case .medium: .big
        case .big: .small
        }
    }
}

private struct POSDashboardView: View {
    @ObservedObject var store: POSStore
    let baseURL: String
    let token: String
    let displayStyle: POSProductDisplayStyle
    let accentColor: Color
    @Binding var isCheckoutOpen: Bool
    @State private var selectedCategory: String?
    @State private var selectedProduct: POSProduct?
    @State private var isArrangeMode = false
    @State private var wobblePhase = false
    @State private var arrangedCategoryNames: [String] = []
    @State private var arrangedProductIDsByScope: [String: [Int]] = [:]
    @State private var draggingCategoryName: String?
    @State private var draggingProductID: Int?
    @State private var lastCategoryDropTarget: String?
    @State private var lastProductDropTarget: Int?
    @State private var productAnimationToken = UUID()
    @State private var productCardSizes: [Int: POSCardSize] = [:]
    @State private var productGridWidth: CGFloat = 720
    @Namespace private var categorySelectionNamespace

    private let allProductsScope = "__all_products__"

    private var categories: [POSCategory] {
        let source = store.bootstrap?.catalog.categories ?? []
        guard !arrangedCategoryNames.isEmpty else {
            return source
        }

        let categoryByName = Dictionary(uniqueKeysWithValues: source.map { ($0.name, $0) })
        let arranged = arrangedCategoryNames.compactMap { categoryByName[$0] }
        let missing = source.filter { !arrangedCategoryNames.contains($0.name) }
        return arranged + missing
    }

    private var products: [POSProduct] {
        guard let selectedCategory else { return [] }

        let source = store.bootstrap?.catalog.products.filter { $0.category == selectedCategory } ?? []
        return orderedProducts(source, scope: selectedCategory)
    }

    private func orderedProducts(_ source: [POSProduct], scope: String) -> [POSProduct] {
        guard let arrangedIDs = arrangedProductIDsByScope[scope], !arrangedIDs.isEmpty else {
            return source
        }

        let productByID = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        let arranged = arrangedIDs.compactMap { productByID[$0] }
        let missing = source.filter { !arrangedIDs.contains($0.id) }
        return arranged + missing
    }

    private func arrangeScope(for category: String?) -> String {
        category ?? allProductsScope
    }

    private struct ProductTilePlacement: Identifiable {
        let product: POSProduct
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var id: Int { product.id }
    }

    private func productTilePlacements(width: CGFloat, spacing: CGFloat) -> (placements: [ProductTilePlacement], height: CGFloat) {
        let columns = 4
        let cell = max(72, (width - (spacing * CGFloat(columns - 1))) / CGFloat(columns))
        var placements: [ProductTilePlacement] = []
        var occupied: Set<String> = []

        for product in products {
            let cardSize = productCardSize(for: product)
            let columnSpan = min(max(1, cardSize.columnSpan), columns)
            let rowSpan = max(1, cardSize.rowSpan)
            let slot = firstAvailableProductTileSlot(columnSpan: columnSpan, rowSpan: rowSpan, columns: columns, occupied: occupied)

            for row in slot.row..<(slot.row + rowSpan) {
                for column in slot.column..<(slot.column + columnSpan) {
                    occupied.insert(productTileKey(row: row, column: column))
                }
            }

            let tileWidth = (cell * CGFloat(columnSpan)) + (spacing * CGFloat(columnSpan - 1))
            let tileHeight = (cell * CGFloat(rowSpan)) + (spacing * CGFloat(rowSpan - 1))

            placements.append(ProductTilePlacement(
                product: product,
                x: CGFloat(slot.column) * (cell + spacing),
                y: CGFloat(slot.row) * (cell + spacing),
                width: tileWidth,
                height: tileHeight
            ))
        }

        let height = placements.map { $0.y + $0.height }.max() ?? 0
        return (placements, height)
    }

    private func firstAvailableProductTileSlot(columnSpan: Int, rowSpan: Int, columns: Int, occupied: Set<String>) -> (row: Int, column: Int) {
        for row in 0..<10_000 {
            for column in 0...(columns - columnSpan) {
                if canPlaceProductTile(row: row, column: column, columnSpan: columnSpan, rowSpan: rowSpan, occupied: occupied) {
                    return (row, column)
                }
            }
        }

        return (0, 0)
    }

    private func canPlaceProductTile(row: Int, column: Int, columnSpan: Int, rowSpan: Int, occupied: Set<String>) -> Bool {
        for checkRow in row..<(row + rowSpan) {
            for checkColumn in column..<(column + columnSpan) {
                if occupied.contains(productTileKey(row: checkRow, column: checkColumn)) {
                    return false
                }
            }
        }

        return true
    }

    private func productTileKey(row: Int, column: Int) -> String {
        "\(row)-\(column)"
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
                InitialLoadingView(accentColor: accentColor)
            } else if store.bootstrap != nil {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(categories) { category in
                                    POSCategoryChip(
                                        title: category.name.uppercased(),
                                        isSelected: selectedCategory == category.name,
                                        isArranging: isArrangeMode,
                                        wobblePhase: wobblePhase,
                                        namespace: categorySelectionNamespace,
                                        accentColor: accentColor
                                    ) {
                                        withAnimation(.spring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.05)) {
                                            selectedCategory = category.name
                                            productAnimationToken = UUID()
                                        }
                                    } onArrange: {
                                        enterArrangeMode()
                                    }
                                    .onDrag {
                                        enterArrangeMode()
                                        draggingCategoryName = category.name
                                        return NSItemProvider(object: category.name as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: POSCategoryDropDelegate(
                                            targetName: category.name,
                                            draggingName: $draggingCategoryName,
                                            lastDropTarget: $lastCategoryDropTarget,
                                            categoryNames: $arrangedCategoryNames
                                        )
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        if store.isRefreshing {
                            ProgressView()
                                .tint(accentColor)
                        }

                        if isArrangeMode {
                            Button {
                                finishArrangeMode()
                            } label: {
                                Text("done")
                                    .font(GlacialFont.caption(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 18)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))

                ZStack {
                    switch displayStyle {
                    case .productCard:
                        let spacing: CGFloat = 14
                        let layout = productTilePlacements(width: productGridWidth, spacing: spacing)

                        ZStack(alignment: .topLeading) {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        productGridWidth = max(1, proxy.size.width)
                                    }
                                    .onChange(of: proxy.size.width) { _, width in
                                        productGridWidth = max(1, width)
                                    }
                            }

                            ForEach(layout.placements) { placement in
                                posProductCard(for: placement.product)
                                    .frame(width: placement.width, height: placement.height)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                    .position(x: placement.x + (placement.width / 2), y: placement.y + (placement.height / 2))
                                    .modifier(productReorderModifier(for: placement.product))
                            }
                        }
                        .frame(height: max(layout.height, 1), alignment: .topLeading)
                    case .grabGrid:
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(products) { product in
                                POSCompactProductCard(
                                    product: product,
                                    imageURL: store.imageURL(for: product),
                                    quantityInCart: store.quantityInCart(for: product),
                                    accentColor: accentColor,
                                    isArranging: isArrangeMode,
                                    wobblePhase: wobblePhase
                                ) {
                                    handleProductTap(product)
                                } onArrange: {
                                    enterArrangeMode()
                                }
                                .modifier(productReorderModifier(for: product))
                            }
                        }
                    case .simpleList:
                        VStack(spacing: 10) {
                            ForEach(products) { product in
                                POSProductListRow(
                                    product: product,
                                    imageURL: store.imageURL(for: product),
                                    quantityInCart: store.quantityInCart(for: product),
                                    accentColor: accentColor,
                                    isArranging: isArrangeMode,
                                    wobblePhase: wobblePhase
                                ) {
                                    handleProductTap(product)
                                } onArrange: {
                                    enterArrangeMode()
                                }
                                .modifier(productReorderModifier(for: product))
                            }
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: productAnimationToken)
            } else {
                EmptyKitchenView()
            }
        }
        .sheet(item: $selectedProduct) { product in
            POSProductSheet(product: product, imageURL: store.imageURL(for: product), accentColor: accentColor) { toppings in
                store.add(product: product, toppings: toppings)
                selectedProduct = nil
            }
        }
        .onChange(of: store.bootstrap) { _, bootstrap in
            guard let catalog = bootstrap?.catalog else { return }
            syncArrangeOrders(catalog: catalog)
        }
        .onChange(of: displayStyle) { _, _ in
            productAnimationToken = UUID()
        }
    }

    private func posProductCard(for product: POSProduct) -> some View {
        POSProductCard(
            product: product,
            imageURL: store.imageURL(for: product),
            quantityInCart: store.quantityInCart(for: product),
            cardSize: productCardSize(for: product),
            accentColor: accentColor,
            isArranging: isArrangeMode,
            wobblePhase: wobblePhase
        ) {
            handleProductTap(product)
        } onArrange: {
            enterArrangeMode()
        } onCycleSize: {
            cycleProductCardSize(product)
        }
    }

    private func handleProductTap(_ product: POSProduct) {
        if isArrangeMode {
            cycleProductCardSize(product)
        } else {
            selectedProduct = product
        }
    }

    private func productCardSize(for product: POSProduct) -> POSCardSize {
        productCardSizes[product.id] ?? .small
    }

    private func cycleProductCardSize(_ product: POSProduct) {
        guard displayStyle == .productCard else {
            Haptics.impact(.light)
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            productCardSizes[product.id] = productCardSize(for: product).next
            productAnimationToken = UUID()
        }
        Haptics.selectionChanged()
    }

    private func productReorderModifier(for product: POSProduct) -> some ViewModifier {
        POSProductReorderModifier(
            productID: product.id,
            scope: arrangeScope(for: selectedCategory),
            draggingProductID: $draggingProductID,
            lastDropTarget: $lastProductDropTarget,
            productIDsByScope: $arrangedProductIDsByScope,
            onBeginDrag: { enterArrangeMode() }
        )
    }

    private func syncArrangeOrders(catalog: POSCatalog) {
        if arrangedCategoryNames.isEmpty {
            arrangedCategoryNames = catalog.categories.map(\.name)
        } else {
            arrangedCategoryNames = arrangedCategoryNames.filter { name in
                catalog.categories.contains { $0.name == name }
            }
            for category in catalog.categories where !arrangedCategoryNames.contains(category.name) {
                arrangedCategoryNames.append(category.name)
            }
        }

        let allIDs = catalog.products.map(\.id)
        arrangedProductIDsByScope[allProductsScope] = normalizedOrder(
            existing: arrangedProductIDsByScope[allProductsScope],
            source: allIDs
        )

        for category in catalog.categories {
            let productIDs = catalog.products.filter { $0.category == category.name }.map(\.id)
            arrangedProductIDsByScope[category.name] = normalizedOrder(
                existing: arrangedProductIDsByScope[category.name],
                source: productIDs
            )
        }

        let categoryNames = catalog.categories.map(\.name)
        if selectedCategory == nil || !categoryNames.contains(selectedCategory ?? "") {
            selectedCategory = categoryNames.first
            productAnimationToken = UUID()
        }
    }

    private func normalizedOrder(existing: [Int]?, source: [Int]) -> [Int] {
        guard let existing, !existing.isEmpty else {
            return source
        }

        let sourceSet = Set(source)
        var next = existing.filter { sourceSet.contains($0) }
        for id in source where !next.contains(id) {
            next.append(id)
        }
        return next
    }

    private func enterArrangeMode() {
        guard !isArrangeMode else { return }
        Haptics.notification(.success)
        withAnimation(.snappy(duration: 0.22)) {
            isArrangeMode = true
            wobblePhase = true
        }
    }

    private func finishArrangeMode() {
        withAnimation(.snappy(duration: 0.2)) {
            isArrangeMode = false
            wobblePhase = false
            draggingCategoryName = nil
            draggingProductID = nil
            lastCategoryDropTarget = nil
            lastProductDropTarget = nil
        }
    }

    private func canMoveCategory(_ name: String, offset: Int) -> Bool {
        guard let index = arrangedCategoryNames.firstIndex(of: name) else { return false }
        return arrangedCategoryNames.indices.contains(index + offset)
    }

    private func moveCategory(_ name: String, offset: Int) {
        guard let index = arrangedCategoryNames.firstIndex(of: name) else { return }
        let destination = index + offset
        guard arrangedCategoryNames.indices.contains(destination) else { return }

        withAnimation(.snappy(duration: 0.2)) {
            arrangedCategoryNames.swapAt(index, destination)
        }
        Haptics.impact(.light)
    }

    private func canMoveProduct(_ id: Int, offset: Int) -> Bool {
        let scope = arrangeScope(for: selectedCategory)
        guard let order = arrangedProductIDsByScope[scope],
              let index = order.firstIndex(of: id) else {
            return false
        }
        return order.indices.contains(index + offset)
    }

    private func moveProduct(_ id: Int, offset: Int) {
        let scope = arrangeScope(for: selectedCategory)
        guard var order = arrangedProductIDsByScope[scope],
              let index = order.firstIndex(of: id) else {
            return
        }

        let destination = index + offset
        guard order.indices.contains(destination) else { return }

        withAnimation(.snappy(duration: 0.2)) {
            order.swapAt(index, destination)
            arrangedProductIDsByScope[scope] = order
        }
        Haptics.impact(.light)
    }
}

private struct POSCategoryDropDelegate: DropDelegate {
    let targetName: String
    @Binding var draggingName: String?
    @Binding var lastDropTarget: String?
    @Binding var categoryNames: [String]

    func dropEntered(info: DropInfo) {
        guard let draggingName,
              draggingName != targetName,
              let fromIndex = categoryNames.firstIndex(of: draggingName),
              let toIndex = categoryNames.firstIndex(of: targetName) else {
            return
        }

        lastDropTarget = targetName
        withAnimation(.snappy(duration: 0.18)) {
            categoryNames.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        Haptics.impact(.light)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingName = nil
        lastDropTarget = nil
        return true
    }
}

private struct POSProductReorderModifier: ViewModifier {
    let productID: Int
    let scope: String
    @Binding var draggingProductID: Int?
    @Binding var lastDropTarget: Int?
    @Binding var productIDsByScope: [String: [Int]]
    let onBeginDrag: () -> Void

    func body(content: Content) -> some View {
        content
            .onDrag {
                onBeginDrag()
                draggingProductID = productID
                return NSItemProvider(object: "\(productID)" as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: POSProductDropDelegate(
                    targetID: productID,
                    scope: scope,
                    draggingProductID: $draggingProductID,
                    lastDropTarget: $lastDropTarget,
                    productIDsByScope: $productIDsByScope
                )
            )
    }
}

private struct POSProductDropDelegate: DropDelegate {
    let targetID: Int
    let scope: String
    @Binding var draggingProductID: Int?
    @Binding var lastDropTarget: Int?
    @Binding var productIDsByScope: [String: [Int]]

    func dropEntered(info: DropInfo) {
        guard let draggingProductID,
              draggingProductID != targetID,
              var order = productIDsByScope[scope],
              let fromIndex = order.firstIndex(of: draggingProductID),
              let toIndex = order.firstIndex(of: targetID) else {
            return
        }

        lastDropTarget = targetID
        withAnimation(.snappy(duration: 0.18)) {
            order.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
            productIDsByScope[scope] = order
        }
        Haptics.impact(.light)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProductID = nil
        lastDropTarget = nil
        return true
    }
}

private struct POSOperatorButton: View {
    let `operator`: POSOperator
    let shift: POSShiftEnvelope
    let isSubmitting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(AppPalette.ink)

                Circle()
                    .fill(shift.isOpen ? AppPalette.green : AppPalette.orange)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.white, lineWidth: 1.4))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("POS operator \(`operator`.name)")
        .disabled(isSubmitting)
        .opacity(isSubmitting ? 0.68 : 1)
    }
}

private struct POSShiftCard: View {
    let `operator`: POSOperator
    let shift: POSShiftEnvelope
    let isSubmitting: Bool
    let accentColor: Color
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

private struct POSShiftControlSheet: View {
    let `operator`: POSOperator
    let shift: POSShiftEnvelope
    let isSubmitting: Bool
    let accentColor: Color
    let onOpenShift: () -> Void
    let onCashIn: () -> Void
    let onCashOut: () -> Void
    let onCloseShift: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 13) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 42, height: 42)
                        .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OPERATOR")
                            .font(GlacialFont.caption(.bold))
                            .tracking(2)
                            .foregroundStyle(accentColor)
                        Text(`operator`.name.uppercased())
                            .font(GlacialFont.custom(28, .medium))
                            .tracking(1.4)
                            .foregroundStyle(AppPalette.ink)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shift.isOpen ? "SHIFT OPEN" : "SHIFT CLOSED")
                                .font(GlacialFont.subheadline(.medium))
                                .tracking(1.8)
                                .foregroundStyle(AppPalette.ink)
                            if let activeShift = shift.shift {
                                Text("Shift #\(activeShift.id)")
                                    .font(GlacialFont.caption())
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }

                        Spacer()

                        Text(shift.isOpen ? "ready" : "closed")
                            .font(GlacialFont.caption(.bold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(shift.isOpen ? AppPalette.green : accentColor)
                            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let recap = shift.recap {
                        HStack(spacing: 10) {
                            POSShiftRecapTile(title: "ORDERS", value: "\(recap.orders)")
                            POSShiftRecapTile(title: "REVENUE", value: "\(Int(recap.revenue).formatted())")
                            POSShiftRecapTile(title: "CASH", value: "\(Int(recap.expectedCash).formatted())")
                        }
                    }
                }
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.8), lineWidth: 1)
                )

                VStack(spacing: 10) {
                    if shift.isOpen {
                        POSShiftMenuButton(title: "CASH IN", icon: "plus", isSubmitting: isSubmitting, accentColor: accentColor, action: onCashIn)
                        POSShiftMenuButton(title: "CASH OUT", icon: "minus", isSubmitting: isSubmitting, accentColor: accentColor, action: onCashOut)
                        POSShiftMenuButton(title: "CLOSE SHIFT", icon: "lock", isSubmitting: isSubmitting, accentColor: accentColor, tone: .danger, action: onCloseShift)
                    } else {
                        POSShiftMenuButton(title: "OPEN SHIFT", icon: "lock.open", isSubmitting: isSubmitting, accentColor: accentColor, action: onOpenShift)
                    }
                }

                Spacer()
            }
            .padding(20)
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("AUTHENTICATION")
                        .font(GlacialFont.subheadline(.medium))
                        .tracking(2.4)
                        .foregroundStyle(AppPalette.ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("SAVE") {
                        dismiss()
                    }
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.8)
                    .foregroundStyle(accentColor)
                }
            }
        }
    }
}

private struct POSShiftRecapTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(GlacialFont.caption2(.bold))
                .foregroundStyle(AppPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct POSShiftMenuButton: View {
    enum Tone {
        case normal
        case danger
    }

    let title: String
    let icon: String
    let isSubmitting: Bool
    let accentColor: Color
    var tone: Tone = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(tone == .danger ? AppPalette.red : accentColor)
                    .background((tone == .danger ? AppPalette.red : accentColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                Text(title)
                    .font(GlacialFont.subheadline(.medium))
                    .tracking(1.2)
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.muted)
            }
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppPalette.line.opacity(0.8), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .opacity(isSubmitting ? 0.65 : 1)
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
    let accentColor: Color
    let submit: (Double, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var openingCash = ""
    @State private var notes = ""

    var body: some View {
        POSShiftFormShell(
            title: "OPEN SHIFT",
            isSubmitting: isSubmitting,
            canSubmit: parsedOpeningCash != nil,
            accentColor: accentColor,
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
    let accentColor: Color
    let submit: (Double, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var reason = ""

    var body: some View {
        POSShiftFormShell(
            title: type.title.uppercased(),
            isSubmitting: isSubmitting,
            canSubmit: parsedAmount != nil && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            accentColor: accentColor,
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
    let accentColor: Color
    let submit: (Double?, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var closingCash = ""
    @State private var notes = ""

    var body: some View {
        POSShiftFormShell(
            title: "CLOSE SHIFT",
            isSubmitting: isSubmitting,
            canSubmit: closingCash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedClosingCash != nil,
            accentColor: accentColor,
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
    let isSubmitting: Bool
    let canSubmit: Bool
    let accentColor: Color
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
                            Text(isSubmitting ? "SAVING" : "SAVE")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2.2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting || !canSubmit)
                    .opacity(isSubmitting || !canSubmit ? 0.55 : 1)
                }
                .padding(20)
                .background(.white)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(GlacialFont.subheadline(.medium))
                        .tracking(2.4)
                        .foregroundStyle(AppPalette.ink)
                }
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

private extension UIImage {
    func normalizedForPOSCard() -> UIImage {
        let maxSide: CGFloat = 1600
        let largestSide = max(size.width, size.height)
        let scale = largestSide > maxSide ? maxSide / largestSide : 1
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private struct POSCategoryChip: View {
    let title: String
    let isSelected: Bool
    let isArranging: Bool
    let wobblePhase: Bool
    let namespace: Namespace.ID
    let accentColor: Color
    let action: () -> Void
    let onArrange: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(GlacialFont.subheadline(.bold))
                .tracking(1.4)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 17)
                .frame(height: 40)
                .foregroundStyle(isSelected ? .white : AppPalette.ink)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accentColor)
                            .matchedGeometryEffect(id: "pos-category-selection", in: namespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .scaleEffect(isArranging ? 0.985 : 1)
        .animation(.snappy(duration: 0.18), value: isArranging)
    }
}

private struct POSProductAreaWallpaper: View {
    var body: some View {
        GeometryReader { proxy in
            Image("POSLightWallpaper")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .opacity(0.28)
                .overlay(.white.opacity(0.62))
                .clipped()
        }
        .allowsHitTesting(false)
    }
}

private struct POSProductCard: View {
    let product: POSProduct
    let imageURL: URL?
    let quantityInCart: Int
    let cardSize: POSCardSize
    let accentColor: Color
    let isArranging: Bool
    let wobblePhase: Bool
    let action: () -> Void
    let onArrange: () -> Void
    let onCycleSize: () -> Void

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    POSProductImage(url: imageURL)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    LinearGradient(
                        colors: [
                            .black.opacity(0.02),
                            .black.opacity(0.22),
                            .black.opacity(0.64)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(product.name.uppercased())
                            .font(GlacialFont.headline(.semibold))
                            .tracking(1.1)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(14)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)

                    VStack {
                        HStack {
                            Spacer()

                            if !isArranging {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 38, height: 38)
                                        .background(accentColor.opacity(0.94), in: Circle())

                                    if quantityInCart > 0 {
                                        Text("\(quantityInCart)")
                                            .font(GlacialFont.caption2(.bold))
                                            .foregroundStyle(accentColor)
                                            .frame(minWidth: 17, minHeight: 17)
                                            .background(.white, in: Circle())
                                            .offset(x: 3, y: -3)
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(12)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                    if isArranging {
                        VStack {
                            HStack {
                                Button(action: onCycleSize) {
                                    Text(cardSize.shortLabel)
                                        .font(GlacialFont.caption(.bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 30, height: 30)
                                            .background(.ultraThinMaterial, in: Circle())
                                            .overlay(
                                                Circle()
                                                    .fill(accentColor.opacity(0.78))
                                                    .blendMode(.plusLighter)
                                            )
                                        .overlay(
                                            Circle()
                                                .stroke(.white.opacity(0.42), lineWidth: 1)
                                        )
                                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                                }
                                .buttonStyle(.plain)

                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(12)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(quantityInCart > 0 ? accentColor.opacity(0.8) : AppPalette.line.opacity(0.8), lineWidth: 1)
            )
            .scaleEffect(isArranging ? 0.992 : 1)
            .animation(.snappy(duration: 0.18), value: isArranging)
        }
        .buttonStyle(.plain)
    }
}

private struct POSCompactProductCard: View {
    let product: POSProduct
    let imageURL: URL?
    let quantityInCart: Int
    let accentColor: Color
    let isArranging: Bool
    let wobblePhase: Bool
    let action: () -> Void
    let onArrange: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    POSProductImage(url: imageURL)
                        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118)
                        .clipped()

                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.56)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.name.uppercased())
                                .font(GlacialFont.subheadline(.semibold))
                                .tracking(0.8)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Spacer()

                        if !isArranging {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(accentColor.opacity(0.96), in: Circle())
                        }
                    }
                    .padding(10)

                    EmptyView()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(quantityInCart > 0 ? accentColor.opacity(0.8) : AppPalette.line.opacity(0.78), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if quantityInCart > 0, !isArranging {
                    Text("\(quantityInCart)")
                        .font(GlacialFont.caption2(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(accentColor, in: Circle())
                        .padding(7)
                }
            }
            .scaleEffect(isArranging ? 0.992 : 1)
            .animation(.snappy(duration: 0.18), value: isArranging)
        }
        .buttonStyle(.plain)
    }

}

private struct POSProductListRow: View {
    let product: POSProduct
    let imageURL: URL?
    let quantityInCart: Int
    let accentColor: Color
    let isArranging: Bool
    let wobblePhase: Bool
    let action: () -> Void
    let onArrange: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                POSProductImage(url: imageURL)
                    .frame(width: 82, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(product.name.uppercased())
                        .font(GlacialFont.headline(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text("\(Int(product.price).formatted()) VND")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(accentColor)
                }

                Spacer()

                if !isArranging {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(accentColor, in: Circle())

                        if quantityInCart > 0 {
                            Text("\(quantityInCart)")
                                .font(GlacialFont.caption2(.bold))
                                .foregroundStyle(accentColor)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(.white, in: Circle())
                                .offset(x: 3, y: -3)
                        }
                    }
                }
            }
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(quantityInCart > 0 ? accentColor.opacity(0.8) : AppPalette.line.opacity(0.75), lineWidth: 1)
            )
            .scaleEffect(isArranging ? 0.992 : 1)
            .animation(.snappy(duration: 0.18), value: isArranging)
        }
        .buttonStyle(.plain)
    }
}

private struct POSProductImage: View {
    let url: URL?

    var body: some View {
        if let url, url.isFileURL {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                POSProductImageFallback()
            }
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    POSProductImageFallback()
                case .empty:
                    ZStack {
                        AppPalette.card
                        ProgressView()
                            .tint(AppPalette.orange)
                    }
                @unknown default:
                    AppPalette.card
                }
            }
        }
    }
}

private struct POSProductImageFallback: View {
    var body: some View {
        ZStack {
            AppPalette.card
            Image(systemName: "fork.knife")
                .font(.title3)
                .foregroundStyle(AppPalette.orange)
        }
    }
}

private struct POSProductSheet: View {
    let product: POSProduct
    let imageURL: URL?
    let accentColor: Color
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
                VStack(alignment: .leading, spacing: 26) {
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
                                Divider()
                                    .background(AppPalette.line.opacity(0.8))

                                Text(group.0.uppercased())
                                    .font(GlacialFont.caption(.bold))
                                    .tracking(1.8)
                                    .foregroundStyle(accentColor)
                                    .padding(.top, 4)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                                    ForEach(group.1) { topping in
                                        POSToppingOption(
                                            topping: topping,
                                            isSelected: selectedToppingIDs.contains(topping.id),
                                            accentColor: accentColor
                                        ) {
                                            toggle(topping)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .background(Color.white.ignoresSafeArea())
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(AppPalette.ink)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onAdd(selectedToppings)
                } label: {
                    HStack {
                        Text("Add to cart")
                        Spacer()
                        Text("\(Int(total).formatted()) VND")
                    }
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .padding(.horizontal, 18)
                    .foregroundStyle(.white)
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(20)
                .background(.white)
            }
        }
    }

    private var productHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                POSProductImage(url: imageURL)
                .frame(maxWidth: .infinity, minHeight: 310, maxHeight: 310)
                .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.0), .black.opacity(0.24), .black.opacity(0.68)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text(product.category.uppercased())
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.82))
                    Text(product.name.uppercased())
                        .font(GlacialFont.custom(34, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(Int(product.price).formatted()) VND")
                        .font(GlacialFont.title3(.semibold))
                        .foregroundStyle(.white.opacity(0.94))
                }
                .padding(20)
            }

            if let description = product.description, !description.isEmpty {
                Text(description)
                    .font(GlacialFont.subheadline())
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(4)
                    .padding(.horizontal, 2)
                    .padding(.top, 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 14)
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
    let accentColor: Color
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
            .background(isSelected ? accentColor : AppPalette.card, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

private struct POSCartAccessButton: View {
    let itemCount: Int
    let total: Double
    let onCheckout: () -> Void

    var body: some View {
        Button(action: onCheckout) {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bag")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)

                    Text("\(itemCount)")
                        .font(GlacialFont.caption2(.bold))
                        .foregroundStyle(AppPalette.orange)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.white, in: Circle())
                        .offset(x: 7, y: -6)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("checkout")
                        .font(GlacialFont.caption(.bold))
                        .tracking(2)
                    Text("\(Int(total).formatted()) VND")
                        .font(GlacialFont.subheadline(.semibold))
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .background(AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: AppPalette.orange.opacity(0.24), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Checkout \(itemCount) items")
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
    let accentColor: Color
    let productImageURL: (POSProduct) -> URL?
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
                        recapSection
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
                    }
                    .padding(20)
                }

                VStack(spacing: 12) {
                    Divider()
                    VStack(spacing: 6) {
                        POSCheckoutTotalRow(title: "subtotal", value: total)
                        if parsedDiscountPercent > 0 {
                            POSCheckoutTotalRow(title: "discount \(String(format: "%.1f", parsedDiscountPercent))%", value: -discountAmount, tint: accentColor)
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
                            Text(isSubmitting ? "COMPLETING" : "COMPLETE")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2.2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.72 : 1)
                }
                .padding(20)
                .background(.white)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("")
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

    private var recapSection: some View {
        POSCheckoutChoiceGroup(title: "order recap") {
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    POSCheckoutRecapLine(
                        index: index + 1,
                        line: line,
                        imageURL: productImageURL(line.product)
                    )

                    if index < lines.count - 1 {
                        Divider()
                            .background(AppPalette.line.opacity(0.8))
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var sourceSelector: some View {
        POSCheckoutChoiceGroup(title: "order source") {
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
        POSCheckoutChoiceGroup(title: "customer info") {
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
                        .foregroundStyle(accentColor)
                    }
                    .padding(12)
                    .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    TextField("name, phone number, email", text: $customerSearch)
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
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
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
                            POSCustomerResultRow(customer: customer, accentColor: accentColor) {
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
                            .frame(width: isCreateCustomerOpen ? 18 : nil)
                        if !isCreateCustomerOpen {
                            Text("NEW CUSTOMER")
                        }
                    }
                    .font(GlacialFont.caption(.bold))
                    .tracking(isCreateCustomerOpen ? 0 : 1.6)
                    .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)

                if isCreateCustomerOpen {
                    VStack(spacing: 8) {
                        TextField("name", text: $newCustomerName)
                            .textInputAutocapitalization(.words)
                        TextField("phone number", text: $newCustomerPhone)
                            .keyboardType(.phonePad)
                        TextField("email optional", text: $newCustomerEmail)
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
        POSCheckoutChoiceGroup(title: "order notes") {
            TextField("Optional order note", text: $notes, axis: .vertical)
                .font(GlacialFont.subheadline())
                .lineLimit(2...4)
                .padding(12)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sourcePill(_ source: POSOrderSource) -> some View {
        POSCheckoutPill(title: source.label, isSelected: orderSource == source, accentColor: accentColor) {
            orderSource = source
        }
    }

    private func paymentPill(_ method: POSPaymentMethod) -> some View {
        POSCheckoutPill(title: method.label, isSelected: paymentMethod == method, accentColor: accentColor) {
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
    let accentColor: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(accentColor)
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
                    .foregroundStyle(accentColor)
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
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(GlacialFont.caption(.bold))
                .tracking(1.1)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isSelected ? .white : AppPalette.ink)
                .background(isSelected ? accentColor : AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

private struct POSCheckoutRecapLine: View {
    let index: Int
    let line: POSCartLine
    let imageURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            POSProductImage(url: imageURL)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.75), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index). \(line.product.name)")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)

                    Spacer(minLength: 8)

                    Text("\(Int(line.product.price * Double(line.quantity)).formatted()) VND")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                if line.quantity > 1 {
                    Text("quantity \(line.quantity)")
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(AppPalette.orange)
                }

                if line.toppings.isEmpty {
                    Text("no toppings")
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                } else {
                    VStack(spacing: 5) {
                        ForEach(line.toppings) { topping in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("+ \(topping.name)")
                                    .font(GlacialFont.caption())
                                    .foregroundStyle(AppPalette.muted)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)

                                Spacer(minLength: 8)

                                Text("\(Int(topping.price * Double(line.quantity)).formatted()) VND")
                                    .font(GlacialFont.caption(.semibold))
                                    .foregroundStyle(AppPalette.orange)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
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

private struct POSRecapSheet: View {
    let recap: POSRecap?
    let isLoading: Bool
    let errorMessage: String?
    let accentColor: Color
    let refresh: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let recap {
                        POSRecapHero(summary: recap.summary, accentColor: accentColor)

                        HStack(spacing: 10) {
                            POSRecapMiniMetric(title: "ORDERS", value: "\(recap.summary.ordersCount)", icon: "receipt", accentColor: accentColor)
                            POSRecapMiniMetric(title: "AVERAGE", value: recap.summary.averageTicket.currencyText, icon: "chart.line.uptrend.xyaxis", accentColor: accentColor)
                        }

                        POSRecapSplitSection(title: "PAYMENT", emptyText: "No payments yet today.", splits: recap.paymentSplit, accentColor: accentColor)
                        POSRecapSplitSection(title: "SOURCE", emptyText: "No sources yet today.", splits: recap.sourceSplit, accentColor: accentColor)
                        POSRecapBestSellersSection(bestSellers: recap.bestSellers, accentColor: accentColor)
                    } else if isLoading {
                        VStack(spacing: 14) {
                            ProgressView()
                                .tint(accentColor)
                            Text("LOADING RECAP")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2)
                                .foregroundStyle(AppPalette.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    }

                    if let errorMessage {
                        ErrorBanner(message: errorMessage, retry: refresh)
                    }

                    Button {
                        refresh()
                    } label: {
                        HStack(spacing: 8) {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }

                            Text(isLoading ? "REFRESHING" : "REFRESH")
                        }
                        .font(GlacialFont.caption(.bold))
                        .tracking(2.2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
                .padding(18)
            }
            .background(Color.white.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(AppPalette.ink)
                }

                ToolbarItem(placement: .principal) {
                    Text("RECAP")
                        .font(GlacialFont.subheadline(.medium))
                        .tracking(2.4)
                        .foregroundStyle(AppPalette.ink)
                }
            }
            .onAppear {
                if recap == nil {
                    refresh()
                }
            }
        }
    }
}

private struct POSRecapHero: View {
    let summary: POSRecapSummary
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TODAY")
                        .font(GlacialFont.caption(.bold))
                        .tracking(2.2)
                        .foregroundStyle(accentColor)

                    Text(summary.salesTotal.currencyText)
                        .font(GlacialFont.custom(38, .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer()

                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 54, height: 54)
                    .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("SALES TOTAL")
                .font(GlacialFont.caption(.bold))
                .tracking(2)
                .foregroundStyle(AppPalette.muted)
        }
        .padding(18)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct POSRecapMiniMetric: View {
    let title: String
    let value: String
    let icon: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(accentColor)
                .frame(width: 34, height: 34)
                .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(GlacialFont.caption2(.bold))
                    .tracking(1.6)
                    .foregroundStyle(AppPalette.muted)

                Text(value)
                    .font(GlacialFont.headline(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct POSRecapSplitSection: View {
    let title: String
    let emptyText: String
    let splits: [POSRecapSplit]
    let accentColor: Color

    var body: some View {
        POSRecapCard(title: title, icon: title == "PAYMENT" ? "creditcard" : "point.3.connected.trianglepath.dotted") {
            if splits.isEmpty {
                POSRecapEmptyLine(text: emptyText)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(splits.enumerated()), id: \.element.id) { index, split in
                        POSRecapSplitRow(split: split, accentColor: accentColor)

                        if index < splits.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
    }
}

private struct POSRecapCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.muted)

                Text(title)
                    .font(GlacialFont.caption(.bold))
                    .tracking(2.2)
                    .foregroundStyle(AppPalette.ink)
            }

            content()
        }
        .padding(14)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct POSRecapSplitRow: View {
    let split: POSRecapSplit
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(split.label.uppercased())
                    .font(GlacialFont.subheadline(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)

                Text("\(split.ordersCount) \(split.ordersCount == 1 ? "order" : "orders")")
                    .font(GlacialFont.caption())
                    .foregroundStyle(AppPalette.muted)
            }

            Spacer()

            Text(split.salesTotal.currencyText)
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 11)
    }
}

private struct POSRecapBestSellersSection: View {
    let bestSellers: [POSBestSeller]
    let accentColor: Color

    var body: some View {
        POSRecapCard(title: "BEST SELLERS", icon: "sparkles") {
            if bestSellers.isEmpty {
                POSRecapEmptyLine(text: "No products sold yet today.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(bestSellers.enumerated()), id: \.element.id) { index, seller in
                        POSBestSellerRow(rank: index + 1, seller: seller, accentColor: accentColor)

                        if index < bestSellers.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
    }
}

private struct POSBestSellerRow: View {
    let rank: Int
    let seller: POSBestSeller
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(GlacialFont.caption(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(accentColor, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(seller.productName)
                    .font(GlacialFont.subheadline(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)

                Text("\(seller.quantity.formatted()) sold")
                    .font(GlacialFont.caption())
                    .foregroundStyle(AppPalette.muted)
            }

            Spacer()

            Text(seller.salesTotal.currencyText)
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 11)
    }
}

private struct POSRecapEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(GlacialFont.subheadline())
            .foregroundStyle(AppPalette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}

private struct SettingsView: View {
    @ObservedObject var store: KitchenStore
    @ObservedObject var posStore: POSStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("POSProductDisplayStyle") private var posProductDisplayStyleRaw = POSProductDisplayStyle.productCard.rawValue
    @AppStorage("POSAccentColor") private var posAccentColorRaw = POSAccentColor.ember.rawValue
    @State private var baseURL: String = ""
    @State private var token: String = ""
    @State private var previewTone: KitchenChimeTone?
    @State private var connectionOpen = false
    @State private var soundOpen = false
    @State private var displayOpen = false
    @State private var catalogOpen = false

    private var selectedPOSDisplayStyle: POSProductDisplayStyle {
        POSProductDisplayStyle(rawValue: posProductDisplayStyleRaw) ?? .productCard
    }

    private var selectedPOSAccentColor: POSAccentColor {
        POSAccentColor(rawValue: posAccentColorRaw) ?? .ember
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsDisclosureCard(
                        title: "emberOS",
                        subtitle: "Server and device token",
                        icon: "bolt.horizontal.circle",
                        isExpanded: $connectionOpen,
                        accentColor: selectedPOSAccentColor.color
                    ) {
                        VStack(spacing: 0) {
                            SettingsTextFieldRow(title: "Base URL", text: $baseURL, isSecure: false)
                            SettingsDivider()
                            SettingsTextFieldRow(title: "emberOS Key", text: $token, isSecure: true)
                        }
                    }

                    SettingsDisclosureCard(
                        title: "Sound",
                        subtitle: store.chimeTone.label,
                        icon: "speaker.wave.2",
                        isExpanded: $soundOpen,
                        accentColor: selectedPOSAccentColor.color
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(KitchenChimeTone.allCases.enumerated()), id: \.element.id) { index, tone in
                                ChimeToneRow(
                                    tone: tone,
                                    isSaved: tone == store.chimeTone,
                                    isPreviewing: tone == previewTone,
                                    accentColor: selectedPOSAccentColor.color
                                ) {
                                    if previewTone == tone, store.chimeTone != tone {
                                        store.saveChimeTone(tone)
                                    } else {
                                        previewTone = tone
                                        store.previewChimeTone(tone)
                                    }
                                }

                                if index < KitchenChimeTone.allCases.count - 1 {
                                    SettingsDivider()
                                }
                            }

                            SettingsDivider()

                            Button("Stop preview") {
                                previewTone = nil
                                store.stopChime()
                            }
                            .font(GlacialFont.subheadline(.semibold))
                            .foregroundStyle(AppPalette.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                        }
                    }

                    SettingsDisclosureCard(
                        title: "POS Display",
                        subtitle: "\(selectedPOSDisplayStyle.label) · \(selectedPOSAccentColor.label)",
                        icon: "rectangle.grid.2x2",
                        isExpanded: $displayOpen,
                        accentColor: selectedPOSAccentColor.color
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(POSProductDisplayStyle.allCases.enumerated()), id: \.element.id) { index, style in
                                Button {
                                    posProductDisplayStyleRaw = style.rawValue
                                    Haptics.impact(.light)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: style.icon)
                                            .font(.headline.weight(.semibold))
                                            .foregroundStyle(style == selectedPOSDisplayStyle ? selectedPOSAccentColor.color : AppPalette.muted)
                                            .frame(width: 28, height: 28)

                                        Text(style.label)
                                            .font(GlacialFont.body(.semibold))
                                            .foregroundStyle(AppPalette.ink)

                                        Spacer()

                                        if style == selectedPOSDisplayStyle {
                                            Image(systemName: "checkmark")
                                                .font(.headline.weight(.bold))
                                                .foregroundStyle(selectedPOSAccentColor.color)
                                        }
                                    }
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if index < POSProductDisplayStyle.allCases.count - 1 {
                                    SettingsDivider()
                                }
                            }

                            SettingsDivider()
                                .padding(.vertical, 4)

                            VStack(alignment: .leading, spacing: 10) {
                                Text("BUTTON COLOR")
                                    .font(GlacialFont.caption(.bold))
                                    .tracking(1.8)
                                    .foregroundStyle(AppPalette.muted)

                                HStack(spacing: 10) {
                                    ForEach(POSAccentColor.allCases) { accent in
                                        Button {
                                            posAccentColorRaw = accent.rawValue
                                            Haptics.selectionChanged()
                                        } label: {
                                            VStack(spacing: 6) {
                                                ZStack {
                                                    Circle()
                                                        .fill(accent.color)
                                                        .frame(width: 34, height: 34)
                                                        .overlay(
                                                            Circle()
                                                                .stroke(.white, lineWidth: 2)
                                                        )
                                                        .shadow(color: accent.color.opacity(0.24), radius: 8, y: 4)

                                                    if accent == selectedPOSAccentColor {
                                                        Image(systemName: "checkmark")
                                                            .font(.caption.weight(.bold))
                                                            .foregroundStyle(.white)
                                                    }
                                                }

                                                Text(accent.label.uppercased())
                                                    .font(GlacialFont.caption2(.bold))
                                                    .tracking(0.7)
                                                    .foregroundStyle(accent == selectedPOSAccentColor ? AppPalette.ink : AppPalette.muted)
                                                    .lineLimit(1)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(
                                                accent == selectedPOSAccentColor ? accent.color.opacity(0.10) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }

                    SettingsDisclosureCard(
                        title: "POS Catalog",
                        subtitle: "Pictures unlocked, inventory locked",
                        icon: "shippingbox",
                        isExpanded: $catalogOpen,
                        accentColor: selectedPOSAccentColor.color
                    ) {
                        VStack(spacing: 14) {
                            POSProductPictureSettingsList(posStore: posStore, accentColor: selectedPOSAccentColor.color)
                            SettingsDivider()
                            LockedCatalogSettingsCard(accentColor: selectedPOSAccentColor.color)
                        }
                    }

                    Button {
                        store.saveSettings(baseURL: baseURL, token: token)
                        dismiss()
                    } label: {
                        Text("SAVE")
                            .font(GlacialFont.subheadline(.medium))
                            .tracking(2.4)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(selectedPOSAccentColor.color, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(18)
            }
            .background(Color.white.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SETTINGS")
                        .font(GlacialFont.subheadline(.medium))
                        .tracking(2.4)
                        .foregroundStyle(AppPalette.ink)
                }
            }
            .onAppear {
                baseURL = store.baseURL
                token = store.kitchenToken
            }
        }
    }
}

private struct SettingsDisclosureCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var isExpanded: Bool
    let accentColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    isExpanded.toggle()
                }
                Haptics.selectionChanged()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: icon)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 38, height: 38)
                        .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(GlacialFont.headline(.semibold))
                            .foregroundStyle(AppPalette.ink)

                        Text(subtitle)
                            .font(GlacialFont.caption())
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.muted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .zIndex(1)

            if isExpanded {
                SettingsDivider()
                    .padding(.horizontal, 14)

                content()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .clipped()
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    @Binding var text: String
    let isSecure: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 118, alignment: .leading)

            if isSecure {
                SecureField(title, text: $text)
                    .font(GlacialFont.subheadline())
                    .foregroundStyle(AppPalette.ink)
                    .textInputAutocapitalization(.never)
            } else {
                TextField(title, text: $text)
                    .font(GlacialFont.subheadline())
                    .foregroundStyle(AppPalette.ink)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.line.opacity(0.66))
            .frame(height: 1)
    }
}

private struct LockedCatalogSettingsCard: View {
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 34, height: 34)
                    .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Catalog editor locked")
                        .font(GlacialFont.headline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("Products and categories are linked to EmberOS inventory. Creation, deletion, price, category, and inventory edits stay locked until the native POS catalog API is ready.")
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 8) {
                LockedCatalogAction(title: "add / edit products", icon: "square.and.pencil", accentColor: accentColor)
                LockedCatalogAction(title: "categories", icon: "rectangle.3.group", accentColor: accentColor)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct POSProductPictureSettingsList: View {
    @ObservedObject var posStore: POSStore
    let accentColor: Color

    private var products: [POSProduct] {
        posStore.bootstrap?.catalog.products.sorted {
            if $0.category == $1.category {
                return $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder
            }

            return $0.category < $1.category
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 34, height: 34)
                    .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Product pictures")
                        .font(GlacialFont.headline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("Local POS image overrides only. EmberOS inventory, website store, prices, categories, and product logic are unchanged.")
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if products.isEmpty {
                Text("Load the POS once, then product pictures will appear here.")
                    .font(GlacialFont.caption())
                    .foregroundStyle(AppPalette.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(products) { product in
                        POSProductPictureSettingsRow(
                            product: product,
                            imageURL: posStore.imageURL(for: product),
                            hasOverride: posStore.productImageOverrideURLs[product.id] != nil,
                            accentColor: accentColor
                        ) { data in
                            await posStore.setProductImageOverride(productID: product.id, data: data)
                        } onReset: {
                            posStore.clearProductImageOverride(productID: product.id)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct POSProductPictureSettingsRow: View {
    let product: POSProduct
    let imageURL: URL?
    let hasOverride: Bool
    let accentColor: Color
    let onPicked: (Data) async -> Void
    let onReset: () -> Void
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 12) {
            POSProductImage(url: imageURL)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.8), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(product.name)
                    .font(GlacialFont.subheadline(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)

                Text(hasOverride ? "custom POS picture" : product.category)
                    .font(GlacialFont.caption())
                    .foregroundStyle(hasOverride ? accentColor : AppPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if hasOverride {
                Button("Reset") {
                    onReset()
                }
                .font(GlacialFont.caption(.bold))
                .foregroundStyle(AppPalette.red)
                .buttonStyle(.plain)
            }

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Text(hasOverride ? "Change" : "Choose")
                    .font(GlacialFont.caption(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.75), lineWidth: 1)
        )
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await onPicked(data)
                }
                selectedPhoto = nil
            }
        }
    }
}

private struct LockedCatalogAction: View {
    let title: String
    let icon: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.muted)
                .frame(width: 24)

            Text(title)
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(AppPalette.muted)

            Spacer()

            Text("locked")
                .font(GlacialFont.caption2(.bold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(11)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.75), lineWidth: 1)
        )
    }
}

private struct ChimeToneRow: View {
    let tone: KitchenChimeTone
    let isSaved: Bool
    let isPreviewing: Bool
    let accentColor: Color
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
                        .foregroundStyle(accentColor)
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
            return accentColor
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

struct POSBootstrapResponse: Decodable, Equatable {
    let `operator`: POSOperator
    let catalog: POSCatalog
    let shift: POSShiftEnvelope
}

struct POSRecapResponse: Decodable, Equatable {
    let recap: POSRecap
}

struct POSRecap: Decodable, Equatable {
    let period: POSRecapPeriod
    let summary: POSRecapSummary
    let paymentSplit: [POSRecapSplit]
    let sourceSplit: [POSRecapSplit]
    let bestSellers: [POSBestSeller]

    enum CodingKeys: String, CodingKey {
        case period
        case summary
        case paymentSplit = "payment_split"
        case sourceSplit = "source_split"
        case bestSellers = "best_sellers"
    }
}

struct POSRecapPeriod: Decodable, Equatable {
    let label: String
    let date: String
    let timezone: String
    let startsAt: String
    let endsAt: String

    enum CodingKeys: String, CodingKey {
        case label
        case date
        case timezone
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }
}

struct POSRecapSummary: Decodable, Equatable {
    let salesTotal: Double
    let ordersCount: Int
    let averageTicket: Double

    enum CodingKeys: String, CodingKey {
        case salesTotal = "sales_total"
        case ordersCount = "orders_count"
        case averageTicket = "average_ticket"
    }
}

struct POSRecapSplit: Identifiable, Decodable, Equatable {
    let key: String
    let label: String
    let ordersCount: Int
    let salesTotal: Double

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case ordersCount = "orders_count"
        case salesTotal = "sales_total"
    }
}

struct POSBestSeller: Identifiable, Decodable, Equatable {
    let productName: String
    let category: String?
    let quantity: Int
    let salesTotal: Double

    var id: String { "\(productName)|\(category ?? "")" }

    enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case category
        case quantity
        case salesTotal = "sales_total"
    }
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

private extension Double {
    var currencyText: String {
        "\(Int(self).formatted()) VND"
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
