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
import Network
import CryptoKit

private enum AppSection {
    case kitchen
    case pos
    case studio

    var label: String {
        switch self {
        case .pos: "POS"
        case .kitchen: "Kitchen"
        case .studio: "Studio"
        }
    }

    var icon: String {
        switch self {
        case .pos: "cart"
        case .kitchen: "house"
        case .studio: "square.grid.2x2"
        }
    }
}

private struct POSCategorySwipeCommand: Equatable {
    let id = UUID()
    let offset: Int
}

private extension View {
    func emberSheetChrome() -> some View {
        self
            .presentationCornerRadius(4)
            .presentationBackground(.white)
    }
}

private enum POSLocalAuthStore {
    private static let pinHashKey = "POSLocalPINHash"
    private static let operatorIDKey = "POSLocalOperatorID"
    private static let operatorNameKey = "POSLocalOperatorName"
    private static let operatorRoleKey = "POSLocalOperatorRole"

    static func cachedOperator(for pin: String) -> POSOperator? {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...6).contains(trimmed.count),
              UserDefaults.standard.string(forKey: pinHashKey) == hash(trimmed) else {
            return nil
        }

        let id = UserDefaults.standard.integer(forKey: operatorIDKey)
        guard id > 0,
              let name = UserDefaults.standard.string(forKey: operatorNameKey),
              let role = UserDefaults.standard.string(forKey: operatorRoleKey) else {
            return nil
        }

        return POSOperator(id: id, name: name, role: role)
    }

    static var hasCachedPIN: Bool {
        UserDefaults.standard.string(forKey: pinHashKey)?.isEmpty == false
    }

    static func save(pin: String, posOperator: POSOperator) {
        UserDefaults.standard.set(hash(pin), forKey: pinHashKey)
        UserDefaults.standard.set(posOperator.id, forKey: operatorIDKey)
        UserDefaults.standard.set(posOperator.name, forKey: operatorNameKey)
        UserDefaults.standard.set(posOperator.role, forKey: operatorRoleKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: pinHashKey)
        UserDefaults.standard.removeObject(forKey: operatorIDKey)
        UserDefaults.standard.removeObject(forKey: operatorNameKey)
        UserDefaults.standard.removeObject(forKey: operatorRoleKey)
    }

    private static func hash(_ pin: String) -> String {
        let salt = Bundle.main.bundleIdentifier ?? "FitbitesKitchen"
        let digest = SHA256.hash(data: Data("\(salt)|\(pin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum POSBootstrapCache {
    private static let key = "POSBootstrapCache"

    static func load() -> POSBootstrapResponse? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder.kitchen.decode(POSBootstrapResponse.self, from: data)
    }

    static func save(_ bootstrap: POSBootstrapResponse) {
        guard let data = try? JSONEncoder.kitchen.encode(bootstrap) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

private enum POSLocalShiftStateStore {
    private static let key = "POSLocalShiftIsOpen"
    private static let openedFromAuthKey = "POSLocalShiftOpenedFromAuth"

    static var hasLocalDecision: Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }

    static var isOpen: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static var isOpenedFromAuth: Bool {
        UserDefaults.standard.bool(forKey: openedFromAuthKey)
    }

    static func markOpen() {
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.set(true, forKey: openedFromAuthKey)
    }

    static func markClosed() {
        UserDefaults.standard.set(false, forKey: key)
        UserDefaults.standard.set(false, forKey: openedFromAuthKey)
    }
}

private struct NoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private extension View {
    @ViewBuilder
    func lightGlassBackground<S: Shape>(_ material: Material, in shape: S) -> some View {
        if UIAccessibility.isReduceTransparencyEnabled {
            background(Color.white, in: shape)
        } else {
            background(material, in: shape)
        }
    }
}

struct ContentView: View {
    @StateObject private var store = KitchenStore()
    @StateObject private var posStore = POSStore()
    @StateObject private var printStore = PrintBridgeStore()
    @StateObject private var studioStore = StudioStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let startsPolling: Bool
    private let showsSplash: Bool
    @State private var selectedSection: AppSection = .kitchen
    @State private var selectedStatus: KitchenStatus? = nil
    @State private var selectedSource: KitchenSource? = nil
    @State private var selectedOrder: KitchenOrder?
    @State private var selectedOnlineOrder: KitchenOnlineOrder?
    @State private var selectedCompletedTicket: CompletedKitchenTicket?
    @State private var pendingOnlineOrderAction: OnlineOrderAction?
    @State private var pendingKitchenCancelOrder: KitchenOrder?
    @State private var settingsOpen = false
    @State private var isPOSShiftMenuOpen = false
    @State private var isPOSStartShiftOpen = false
    @State private var posCashMovementType: POSCashMovementType?
    @State private var isPOSEndShiftOpen = false
    @State private var isPOSCheckoutOpen = false
    @State private var isPOSRecapOpen = false
    @State private var isPOSKeySetupOpen = false
    @State private var isSplashVisible: Bool
    @State private var isPOSArrangeMode = false
    @State private var saleCompletion: POSSaleCompletion?
    @State private var posPinEntry = ""
    @State private var posOpeningCashText = ""
    @State private var currentPOSSessionPIN = ""
    @State private var posPinWelcome: POSPinWelcome?
    @State private var posCategorySwipeCommand = POSCategorySwipeCommand(offset: 0)
    @State private var selectedCompactTab: CompactShellTab = .pos
    @State private var didApplyInitialLaunchSection = false
    @State private var posStaffSessionSkipped = false
    @State private var isPOSUnlocked = false
    @AppStorage("POSStaffSessionToken") private var posStaffSessionToken = ""
    @AppStorage("POSProductDisplayStyle") private var posProductDisplayStyleRaw = POSProductDisplayStyle.productCard.rawValue
    @AppStorage("POSAccentColor") private var posAccentColorRaw = POSAccentColor.ember.rawValue
    @AppStorage("POSToppingCategoryOrder") private var posToppingCategoryOrderRaw = ""
    @AppStorage("POSBrandLogoHidden") private var posBrandLogoHidden = false
    @AppStorage("POSBrandLogoScale") private var posBrandLogoScale = 1.0
    @AppStorage("StudioToken") private var studioToken = ""
    @Namespace private var filterSelectionNamespace

    init(startsPolling: Bool = true, showsSplash: Bool = true) {
        GlacialFont.register()
        self.startsPolling = startsPolling
        self.showsSplash = showsSplash
        _isSplashVisible = State(initialValue: showsSplash)
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
        store.onlineOrders.filter { $0.status == .submitted || $0.status == .accepted }
    }

    private var showsOnlineOrders: Bool {
        true
    }

    private var selectedPOSAccentColor: POSAccentColor {
        POSAccentColor(rawValue: posAccentColorRaw) ?? .ember
    }

    private var canAccessAdminFeatures: Bool {
        isPOSUnlocked && (posStore.bootstrap?.operator.canAccessAdminFeatures ?? false)
    }

    private var hasPOSStaffSession: Bool {
        !posStaffSessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canAccessPOS: Bool {
        isPOSUnlocked
    }

    private var canAccessRecap: Bool {
        isPOSUnlocked
    }

    private var canInputPOSSales: Bool {
        posStore.hasOpenShiftForCurrentOperator
    }

    private var shouldShowPOSPinGate: Bool {
        !isSplashVisible && !isPOSUnlocked && !posStaffSessionSkipped
    }

    private var isPOSAuthOverlayVisible: Bool {
        shouldShowPOSPinGate
    }

    private var isCompactShell: Bool {
        horizontalSizeClass == .compact
    }

    private var activeCompactTab: CompactShellTab {
        selectedCompactTab
    }

    private var onlineOrderActionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingOnlineOrderAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingOnlineOrderAction = nil
                }
            }
        )
    }

    private var kitchenCancelAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingKitchenCancelOrder != nil },
            set: { isPresented in
                if !isPresented {
                    pendingKitchenCancelOrder = nil
                }
            }
        )
    }

    private var settingsSheetBinding: Binding<Bool> {
        Binding(
            get: { settingsOpen && !isCompactShell && canAccessAdminFeatures },
            set: { isPresented in
                if !isPresented {
                    settingsOpen = false
                }
            }
        )
    }

    private var recapSheetBinding: Binding<Bool> {
        Binding(
            get: { isPOSRecapOpen && !isCompactShell && canAccessRecap },
            set: { isPresented in
                if !isPresented {
                    isPOSRecapOpen = false
                }
            }
        )
    }

    private var shiftSheetBinding: Binding<Bool> {
        Binding(
            get: { isPOSShiftMenuOpen && !isCompactShell && canAccessPOS },
            set: { isPresented in
                if !isPresented {
                    isPOSShiftMenuOpen = false
                }
            }
        )
    }

    private func confirmOnlineOrderAction(_ action: OnlineOrderAction) {
        pendingOnlineOrderAction = nil

        Task {
            switch action {
            case .accept(let order):
                await store.acceptOnlineOrder(order)
            case .markPaid(let order):
                await store.markOnlineOrderPaid(order)
            case .sendToKitchen(let order):
                await store.sendOnlineOrderToKitchen(order)
                await posStore.refreshAfterExternalSaleMutation(baseURL: store.baseURL, token: store.kitchenToken)
                await posStore.refreshRecap(baseURL: store.baseURL, token: store.kitchenToken)
            case .decline(let order):
                await store.rejectOnlineOrder(order)
            }
        }
    }

    private func confirmKitchenCancelOrder(_ order: KitchenOrder) {
        pendingKitchenCancelOrder = nil
        Task {
            await store.update(order: order, status: .cancelled)
            await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken)
            await posStore.refreshRecap(baseURL: store.baseURL, token: store.kitchenToken)
        }
    }

    private var posCategorySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 34, coordinateSpace: .local)
            .onEnded { value in
                guard selectedSection == .pos, !isPOSArrangeMode, !isCompactShell else { return }

                let horizontal = value.translation.width
                let vertical = value.translation.height
                let predicted = value.predictedEndTranslation.width

                guard abs(horizontal) > abs(vertical) * 2.45 else { return }
                guard abs(horizontal) > 82 || abs(predicted) > 150 else { return }

                posCategorySwipeCommand = POSCategorySwipeCommand(offset: horizontal < 0 ? 1 : -1)
            }
    }

    private func showSaleCompletion(saleID: Int, total: Double, printResult: PrintReceiptResult) {
        let completion = POSSaleCompletion(saleID: saleID, total: total, printResult: printResult)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            saleCompletion = completion
        }

        guard printResult.canAutoDismiss else { return }

        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            await MainActor.run {
                guard saleCompletion?.id == completion.id else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    saleCompletion = nil
                }
            }
        }
    }

    @MainActor
    private func handleSyncedPOSSale(_ response: POSCreateSaleResponse, queuedSale: POSQueuedSale) async {
        guard response.saleID > 0 else { return }

        printStore.setPrintIntent(saleID: response.saleID, shouldPrint: queuedSale.shouldPrintReceipt)
        var printResult = PrintReceiptResult.skipped
        if queuedSale.shouldPrintReceipt {
            printResult = await printStore.printSaleReceiptNow(saleID: response.saleID)
        }

        guard queuedSale.shouldPrintReceipt else { return }
        showSaleCompletion(saleID: response.saleID, total: queuedSale.completionTotal, printResult: printResult)
    }

    private func syncQueuedPOSSales() {
        posStore.syncQueuedSales(baseURL: store.baseURL, token: store.kitchenToken) { response, queuedSale in
            await handleSyncedPOSSale(response, queuedSale: queuedSale)
        }
        posStore.syncQueuedShiftMutations(baseURL: store.baseURL, token: store.kitchenToken)
    }

    private func selectSection(_ section: AppSection) {
        guard section != .studio || canAccessAdminFeatures else {
            Haptics.impact(.light)
            return
        }

        guard section == .kitchen || section == .studio || canAccessPOS else {
            posStaffSessionSkipped = false
            posPinEntry = ""
            selectedSection = .pos
            selectedCompactTab = .pos
            Haptics.impact(.light)
            return
        }

        closeCompactPanels()

        if section == .pos, !canInputPOSSales {
            selectedSection = .kitchen
            selectedCompactTab = .kitchen
            isPOSShiftMenuOpen = true
            Task {
                await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken)
                await MainActor.run {
                    if posStore.hasOpenShiftForCurrentOperator {
                        selectedSection = .pos
                        selectedCompactTab = .pos
                        isPOSShiftMenuOpen = false
                    } else {
                        selectedSection = .kitchen
                        selectedCompactTab = .kitchen
                        isPOSShiftMenuOpen = true
                    }
                }
            }
            Haptics.impact(.light)
            return
        }

        selectedSection = section
        selectedCompactTab = section == .pos ? .pos : .kitchen

        switch section {
        case .pos:
            Task { await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken) }
        case .kitchen:
            selectedSource = nil
            selectedStatus = nil
            Task { await store.refresh(forceChime: false) }
        case .studio:
            selectedSource = nil
            selectedStatus = nil
            Task { await studioStore.refresh(baseURL: store.baseURL, token: studioToken) }
        }
    }

    private func openPOSRecap() {
        guard canAccessRecap else {
            closeCompactPanelToCurrentSection()
            return
        }

        selectedCompactTab = .recap
        isPOSShiftMenuOpen = false
        settingsOpen = false
        isPOSRecapOpen = true
        Task { await posStore.refreshRecap(baseURL: store.baseURL, token: store.kitchenToken) }
    }

    private func openCompactShiftPanel() {
        guard canAccessPOS else {
            closeCompactPanelToCurrentSection()
            return
        }

        selectedCompactTab = .shift
        isPOSRecapOpen = false
        settingsOpen = false
        isPOSShiftMenuOpen = true

        if posStore.bootstrap == nil {
            Task { await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken) }
        }
    }

    private func openCompactSettingsPanel() {
        guard canAccessAdminFeatures else {
            closeCompactPanelToCurrentSection()
            return
        }

        selectedCompactTab = .settings
        isPOSShiftMenuOpen = false
        isPOSRecapOpen = false
        settingsOpen = true
    }

    private func closeCompactPanels() {
        isPOSShiftMenuOpen = false
        isPOSRecapOpen = false
        settingsOpen = false
    }

    private func closeCompactPanel(returningTo tab: CompactShellTab = .pos) {
        closeCompactPanels()
        selectedCompactTab = tab
    }

    private func closeCompactPanelToCurrentSection() {
        closeCompactPanels()
        selectedCompactTab = selectedSection == .pos ? .pos : .kitchen
    }

    private func presentPOSStartShiftForm() {
        if isCompactShell {
            closeCompactPanelToCurrentSection()
        } else {
            isPOSShiftMenuOpen = false
        }

        Task { @MainActor in
            await Task.yield()
            isPOSStartShiftOpen = true
        }
    }

    private func presentPOSEndShiftForm() {
        if isCompactShell {
            closeCompactPanelToCurrentSection()
        } else {
            isPOSShiftMenuOpen = false
        }

        Task { @MainActor in
            await Task.yield()
            isPOSEndShiftOpen = true
        }
    }

    private func presentPOSCashMovementForm(_ type: POSCashMovementType) {
        if isCompactShell {
            closeCompactPanelToCurrentSection()
        } else {
            isPOSShiftMenuOpen = false
        }

        Task { @MainActor in
            await Task.yield()
            posCashMovementType = type
        }
    }

    private func signInLater() {
        withAnimation(.easeInOut(duration: 0.28)) {
            posStaffSessionSkipped = true
            posPinEntry = ""
            posOpeningCashText = ""
            selectedSection = .kitchen
            selectedCompactTab = .kitchen
            closeCompactPanels()
        }

        Haptics.impact(.light)
    }

    private func submitPOSPin(_ pin: String) {
        guard pin.count >= 4, pin.count <= 6 else { return }

        if let cachedOperator = POSLocalAuthStore.cachedOperator(for: pin) {
            posStore.preparePINOnlyLocalShiftState()
            unlockPOS(posOperator: cachedOperator, pin: pin, openingCash: nil)
            renewPOSSessionInBackground(pin: pin)
            return
        }

        Task {
            guard let response = await posStore.authenticateStaffPIN(
                baseURL: store.baseURL,
                token: store.kitchenToken,
                pin: pin,
                openingCash: nil
            ) else {
                await MainActor.run {
                    posPinEntry = ""
                }
                return
            }

            await MainActor.run {
                posStaffSessionToken = response.sessionToken
                posStaffSessionSkipped = false
                posPinEntry = ""
                posOpeningCashText = ""
                posStore.preparePINOnlyLocalShiftState()
                unlockPOS(posOperator: response.operator, pin: pin, openingCash: nil)
                posStore.setStaffSessionToken(response.sessionToken)
                syncQueuedPOSSales()
            }

            Task { await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken) }
        }
    }

    private func unlockPOS(posOperator: POSOperator, pin: String, openingCash: Double?) {
        POSLocalAuthStore.save(pin: pin, posOperator: posOperator)
        posStore.loadCachedBootstrapIfAvailable()
        posStore.applyLocalOperator(posOperator)
        currentPOSSessionPIN = pin
        withAnimation(.easeOut(duration: 0.16)) {
            isPOSUnlocked = true
            posStaffSessionSkipped = false
            posPinEntry = ""
            posOpeningCashText = ""
            selectedSection = .kitchen
            selectedCompactTab = .kitchen
            if let openingCash {
                posPinWelcome = POSPinWelcome(operatorName: posOperator.name, openingCash: openingCash)
            }
        }
    }

    private func renewPOSSessionInBackground(pin: String) {
        Task {
            guard let response = await posStore.authenticateStaffPIN(
                baseURL: store.baseURL,
                token: store.kitchenToken,
                pin: pin,
                openingCash: nil,
                showsProgress: false
            ) else {
                await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken)
                return
            }

            await MainActor.run {
                posStore.setStaffSessionToken(response.sessionToken)
                posStaffSessionToken = response.sessionToken
                POSLocalAuthStore.save(pin: pin, posOperator: response.operator)
            }

            await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken)
            posStore.syncQueuedSales(baseURL: store.baseURL, token: store.kitchenToken) { response, queuedSale in
                await handleSyncedPOSSale(response, queuedSale: queuedSale)
            }
            posStore.syncQueuedShiftMutations(baseURL: store.baseURL, token: store.kitchenToken)
        }
    }

    private func resetPOSStaffSessionToPIN() {
        withAnimation(.easeInOut(duration: 0.42)) {
            isPOSUnlocked = false
            posStaffSessionSkipped = false
            posPinEntry = ""
            posOpeningCashText = ""
            currentPOSSessionPIN = ""
            posPinWelcome = nil
            selectedSection = .pos
            selectedCompactTab = .pos
            isPOSShiftMenuOpen = false
            isPOSStartShiftOpen = false
            isPOSEndShiftOpen = false
            isPOSCheckoutOpen = false
            isPOSArrangeMode = false
            posCashMovementType = nil
            saleCompletion = nil
            settingsOpen = false
            isPOSRecapOpen = false
        }
        Haptics.notification(.success)
    }

    private func ensurePOSStaffSession() async -> Bool {
        let storedSessionToken = posStaffSessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedSessionToken.isEmpty {
            posStore.setStaffSessionToken(storedSessionToken)
            return true
        }

        let pin = currentPOSSessionPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pin.isEmpty else {
            posStore.errorMessage = "Sign in with your PIN again before opening a shift."
            Haptics.notification(.error)
            return false
        }

        guard let response = await posStore.authenticateStaffPIN(
            baseURL: store.baseURL,
            token: store.kitchenToken,
            pin: pin,
            openingCash: nil,
            showsProgress: false
        ) else {
            if posStore.errorMessage == nil {
                posStore.errorMessage = posStore.pinErrorMessage ?? "Could not connect to emberOS. Try again."
            }
            Haptics.notification(.error)
            return false
        }

        posStaffSessionToken = response.sessionToken
        posStore.setStaffSessionToken(response.sessionToken)
        POSLocalAuthStore.save(pin: pin, posOperator: response.operator)
        return true
    }

    private func applyInitialLaunchSectionIfNeeded() {
        guard !didApplyInitialLaunchSection else { return }
        didApplyInitialLaunchSection = true

        if !canAccessPOS && posStaffSessionSkipped {
            selectedSection = .kitchen
            selectedCompactTab = .kitchen
        } else {
            selectedSection = .kitchen
            selectedCompactTab = .kitchen
        }

        closeCompactPanels()
        selectedSource = nil
        selectedStatus = nil
        selectedOrder = nil
        selectedOnlineOrder = nil
        selectedCompletedTicket = nil
    }

    private func enforceOperatorAccess() {
        if !canAccessPOS {
            selectedSection = posStaffSessionSkipped ? .kitchen : .pos
            selectedCompactTab = posStaffSessionSkipped ? .kitchen : .pos
            closeCompactPanels()
            return
        }

        guard !canAccessAdminFeatures else { return }

        if selectedSection == .studio {
            selectedSection = canAccessPOS ? .pos : .kitchen
        }

        isPOSShiftMenuOpen = false
        if !canAccessRecap {
            isPOSRecapOpen = false
        }
        settingsOpen = false

        if selectedCompactTab == .shift || selectedCompactTab == .settings || (selectedCompactTab == .recap && !canAccessRecap) {
            selectedCompactTab = selectedSection == .kitchen ? .kitchen : .pos
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppPalette.background.ignoresSafeArea()

                if selectedSection == .pos {
                    POSProductAreaWallpaper(assetName: selectedPOSAccentColor.wallpaperAssetName)
                        .ignoresSafeArea()
                        .opacity(isSplashVisible ? 0 : 1)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        HeaderView(
                            activeCount: selectedSection == .kitchen ? store.orders.count : (selectedSection == .studio ? (studioStore.payload?.summary.orders ?? 0) : posStore.productCount),
                            readyCount: selectedSection == .kitchen ? store.summary.ready : (selectedSection == .studio ? Int((studioStore.payload?.summary.revenue ?? 0).rounded()) : posStore.categoryCount),
                            oldestMinutes: selectedSection == .kitchen ? store.oldestElapsedMinutes : nil,
                            isConnected: selectedSection == .kitchen ? store.isConnected : (selectedSection == .studio ? studioStore.isConnected : posStore.isConnected),
                            section: selectedSection,
                            brandLogoURL: posStore.brandLogoOverrideURL,
                            isBrandLogoHidden: posBrandLogoHidden,
                            brandLogoScale: posBrandLogoScale,
                            cartItemCount: posStore.cartItemCount,
                            openTicketCount: posStore.openTicketCount,
                            cartTotal: posStore.cartTotal,
                            pendingSyncCount: posStore.pendingSaleSyncCount + posStore.pendingShiftSyncCount,
                            posAccentColor: selectedPOSAccentColor.color,
                            isPOSArrangeMode: isPOSArrangeMode,
                            isCompact: isCompactShell,
                            studioPeriod: studioStore.selectedPeriod,
                            onHome: { selectSection(.pos) },
                            onFinishPOSArrange: { finishPOSArrangeMode() },
                            onCart: {
                                guard canInputPOSSales else {
                                    selectSection(.pos)
                                    return
                                }
                                isPOSCheckoutOpen = true
                            },
                            onStudioPeriodSelect: { period in
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    studioStore.selectedPeriod = period
                                }
                                Task { await studioStore.refresh(baseURL: store.baseURL, token: studioToken) }
                            }
                        )

                        if selectedSection == .kitchen {
                            MetricsStrip(summary: store.summary, accentColor: selectedPOSAccentColor.color, isCompact: isCompactShell)

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
                                    onSelect: { order in
                                        selectedOnlineOrder = order
                                    },
                                    onAccept: { order in
                                        pendingOnlineOrderAction = .accept(order)
                                    },
                                    onMarkPaid: { order in
                                        pendingOnlineOrderAction = .markPaid(order)
                                    },
                                    onSendToKitchen: { order in
                                        pendingOnlineOrderAction = .sendToKitchen(order)
                                    },
                                    onDecline: { order in
                                        pendingOnlineOrderAction = .decline(order)
                                    },
                                    isCompact: isCompactShell
                                )
                            }

                            QueueSection(
                                orders: filteredOrders,
                                onlineDetailsBySaleID: store.onlineOrderDetailsBySaleID,
                                isInitialLoading: store.isInitialLoading,
                                isRefreshing: store.isRefreshing,
                                accentColor: selectedPOSAccentColor.color,
                                onSelect: { order in
                                    selectedOrder = order
                                },
                                onStatus: { order, status in
                                    handleStatus(order: order, status: status)
                                },
                                isCompact: isCompactShell
                            )
                            .environmentObject(printStore)
                            CompletedKitchenSection(
                                tickets: store.completedTickets,
                                accentColor: selectedPOSAccentColor.color,
                                onSelect: { ticket in
                                    selectedCompletedTicket = ticket
                                },
                                isCompact: isCompactShell
                            )
                            .environmentObject(printStore)
                        } else if selectedSection == .pos {
                            POSDashboardView(
                                store: posStore,
                                baseURL: store.baseURL,
                                token: store.kitchenToken,
                                displayStyle: POSProductDisplayStyle(rawValue: posProductDisplayStyleRaw) ?? .productCard,
                                toppingCategoryOrder: posToppingCategoryOrderRaw.csvValues,
                                accentColor: selectedPOSAccentColor.color,
                                isArrangeMode: $isPOSArrangeMode,
                                isCheckoutOpen: $isPOSCheckoutOpen,
                                categorySwipeCommand: posCategorySwipeCommand,
                                isCompact: isCompactShell
                            )
                        } else {
                            StudioRootView(
                                store: studioStore,
                                baseURL: store.baseURL,
                                studioToken: studioToken,
                                accentColor: selectedPOSAccentColor.color
                            )
                        }
                    }
                    .padding(.horizontal, isCompactShell ? 14 : 18)
                    .padding(.top, isCompactShell ? 8 : 44)
                    .padding(.bottom, isCompactShell ? 92 : 20)
                }
                .refreshable {
                    if selectedSection == .kitchen {
                        await store.refresh(forceChime: false)
                    } else if selectedSection == .pos {
                        await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken)
                    } else {
                        await studioStore.refresh(baseURL: store.baseURL, token: studioToken)
                    }
                }
                .opacity(isSplashVisible ? 0 : 1)
                .animation(.easeInOut(duration: 0.42), value: isSplashVisible)
                .allowsHitTesting(!isPOSAuthOverlayVisible)

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
                    .opacity(isSplashVisible ? 0 : 1)
                    .zIndex(3)
                }

                if let saleCompletion {
                    POSSaleCompletionOverlay(
                        completion: saleCompletion,
                        accentColor: selectedPOSAccentColor.color,
                        onRetry: {
                            Task {
                                let result = await printStore.printSaleReceiptNow(saleID: saleCompletion.saleID)
                                showSaleCompletion(saleID: saleCompletion.saleID, total: saleCompletion.total, printResult: result)
                            }
                        },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.22)) {
                                self.saleCompletion = nil
                            }
                        }
                    )
                        .padding(.top, 92)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .opacity(isSplashVisible ? 0 : 1)
                        .zIndex(4)
                }

                if !isCompactShell {
                    HStack(spacing: 20) {
                        if selectedSection == .pos, canAccessPOS, let bootstrap = posStore.bootstrap {
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
                                selectSection(.pos)
                            } label: {
                                Label("POS", systemImage: "cart")
                            }

                            Button {
                                selectSection(.kitchen)
                            } label: {
                                MenuBadgeLabel(
                                    title: "Kitchen",
                                    systemImage: "house",
                                    count: store.waitingOnlineOrderCount,
                                    accentColor: selectedPOSAccentColor.color
                                )
                            }

                            if canAccessAdminFeatures {
                                Button {
                                    selectSection(.studio)
                                } label: {
                                    Label("Studio", systemImage: "square.grid.2x2")
                                }
                            }

                            if canAccessRecap {
                                Button {
                                    openPOSRecap()
                                } label: {
                                    Label("Recap", systemImage: "chart.bar.xaxis")
                                }
                            }

                            if canAccessAdminFeatures {
                                Button {
                                    openCompactSettingsPanel()
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        } label: {
                            TopMenuIcon(badgeCount: store.waitingOnlineOrderCount, accentColor: selectedPOSAccentColor.color)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(isSplashVisible ? 0 : 1)
                    .animation(.easeInOut(duration: 0.42), value: isSplashVisible)
                    .blur(radius: isPOSAuthOverlayVisible ? 3.2 : 0)
                    .animation(.easeInOut(duration: 0.24), value: isPOSAuthOverlayVisible)
                    .allowsHitTesting(!isPOSAuthOverlayVisible)
                }

                if isCompactShell, canAccessPOS, isPOSShiftMenuOpen {
                    if let bootstrap = posStore.bootstrap {
                        CompactFullScreenPanel(
                            accentColor: selectedPOSAccentColor.color,
                            onDismiss: {
                                withAnimation(.easeInOut(duration: 0.24)) {
                                    closeCompactPanelToCurrentSection()
                                }
                            }
                        ) {
                            POSShiftControlSheet(
                                operator: bootstrap.operator,
                                shift: bootstrap.shift,
                                isSubmitting: posStore.isShiftSubmitting,
                                accentColor: selectedPOSAccentColor.color,
                                onOpenShift: {
                                    presentPOSStartShiftForm()
                                },
                                onCashIn: {
                                    presentPOSCashMovementForm(.deposit)
                                },
                                onCashOut: {
                                    presentPOSCashMovementForm(.withdrawal)
                                },
                                onCloseShift: {
                                    presentPOSEndShiftForm()
                                },
                                onSignOff: {
                                    resetPOSStaffSessionToPIN()
                                },
                                onClose: {
                                    withAnimation(.easeInOut(duration: 0.24)) {
                                        closeCompactPanelToCurrentSection()
                                    }
                                }
                            )
                        }
                        .transition(.opacity)
                        .zIndex(5)
                    }
                }

                if isCompactShell, canAccessRecap, isPOSRecapOpen {
                    CompactFullScreenPanel(
                        accentColor: selectedPOSAccentColor.color,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                closeCompactPanelToCurrentSection()
                            }
                        }
                    ) {
                        POSRecapSheet(
                            recap: posStore.recap,
                            isLoading: posStore.isRecapLoading,
                            errorMessage: posStore.recapErrorMessage,
                            accentColor: selectedPOSAccentColor.color,
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.24)) {
                                    closeCompactPanelToCurrentSection()
                                }
                            }
                        ) {
                            Task { await posStore.refreshRecap(baseURL: store.baseURL, token: store.kitchenToken) }
                        }
                    }
                    .transition(.opacity)
                    .zIndex(5)
                }

                if isCompactShell, canAccessAdminFeatures, settingsOpen {
                    CompactFullScreenPanel(
                        accentColor: selectedPOSAccentColor.color,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                closeCompactPanelToCurrentSection()
                            }
                        }
                    ) {
                        SettingsView(
                            store: store,
                            posStore: posStore,
                            printStore: printStore,
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.24)) {
                                    closeCompactPanelToCurrentSection()
                                }
                            }
                        )
                    }
                    .transition(.opacity)
                    .zIndex(5)
                }

                if isSplashVisible {
                    LaunchSplashView(
                        wallpaperAssetName: selectedPOSAccentColor.wallpaperAssetName,
                        accentColor: selectedPOSAccentColor.color
                    ) {
                        withAnimation(.easeInOut(duration: 0.34)) {
                            isSplashVisible = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(20)
                }

                if shouldShowPOSPinGate {
                    POSStaffPinGateView(
                        pin: $posPinEntry,
                        isSubmitting: posStore.isPinAuthenticating,
                        errorMessage: posStore.pinErrorMessage,
                        accentColor: selectedPOSAccentColor.color,
                        needsEmberKey: store.kitchenToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        onSubmit: submitPOSPin,
                        onSetupKey: {
                            isPOSKeySetupOpen = true
                        },
                        onSignInLater: signInLater
                    )
                    .zIndex(24)
                }

                if let posPinWelcome {
                    POSPinWelcomeOverlay(welcome: posPinWelcome, accentColor: selectedPOSAccentColor.color)
                        .transition(.opacity)
                        .zIndex(25)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isCompactShell && !isSplashVisible && !isPOSAuthOverlayVisible {
                    CompactShellTabBar(
                        selectedTab: activeCompactTab,
                        waitingOrderCount: store.waitingOnlineOrderCount,
                        cartItemCount: posStore.cartItemCount,
                        accentColor: selectedPOSAccentColor.color,
                        canAccessAdminFeatures: canAccessAdminFeatures,
                        canAccessShiftAuth: canAccessPOS,
                        canAccessRecap: canAccessRecap,
                        canAccessPOS: canAccessPOS,
                        onSelect: { selectSection($0) },
                        onShift: {
                            openCompactShiftPanel()
                        },
                        onRecap: { openPOSRecap() },
                        onSettings: { openCompactSettingsPanel() }
                    )
                    .zIndex(20)
                }
            }
            .onAppear {
                UserDefaults.standard.removeObject(forKey: "POSStaffSessionSkipped")
                if POSLocalAuthStore.hasCachedPIN {
                    isSplashVisible = false
                }
                posStore.loadCachedBootstrapIfAvailable()
                posStore.setStaffSessionToken(posStaffSessionToken)
                applyInitialLaunchSectionIfNeeded()
                printStore.receiptLogoURL = posStore.brandLogoOverrideURL
                printStore.receiptLogoScale = posBrandLogoScale
                if startsPolling {
                    store.start()
                    printStore.start()
                }
                if hasPOSStaffSession {
                    syncQueuedPOSSales()
                    Task { await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken) }
                }
            }
            .onChange(of: posStore.brandLogoOverrideURL) { _, logoURL in
                printStore.receiptLogoURL = logoURL
            }
            .onChange(of: posBrandLogoScale) { _, scale in
                printStore.receiptLogoScale = scale
            }
            .onChange(of: posStore.bootstrap?.operator.role) { _, _ in
                enforceOperatorAccess()
            }
            .onChange(of: posStaffSessionToken) { _, token in
                posStore.setStaffSessionToken(token)
                enforceOperatorAccess()
            }
            .onChange(of: scenePhase) { _, phase in
                guard startsPolling else { return }

            if phase == .active {
                store.start()
                printStore.start()
                    if selectedSection == .studio, canAccessAdminFeatures {
                        Task { await studioStore.refresh(baseURL: store.baseURL, token: studioToken) }
                    } else if selectedSection == .pos, hasPOSStaffSession {
                        syncQueuedPOSSales()
                        Task { await posStore.refresh(baseURL: store.baseURL, token: store.kitchenToken) }
                    } else if hasPOSStaffSession {
                        syncQueuedPOSSales()
                        posStore.preloadForSmoothness(baseURL: store.baseURL, token: store.kitchenToken)
                    }
                } else if phase == .background {
                    store.stopPolling()
                    printStore.stop()
                }
            }
            .sheet(item: $selectedOrder) { order in
                OrderDetailView(order: order, onlineDetails: store.onlineOrderDetailsBySaleID[order.id]) { status in
                    if status == .cancelled {
                        pendingKitchenCancelOrder = order
                        selectedOrder = nil
                    } else {
                        selectedOrder = nil
                        Task { await store.update(order: order, status: status) }
                    }
                }
                .presentationDetents([.large])
                .emberSheetChrome()
            }
            .sheet(item: $selectedOnlineOrder) { order in
                OnlineOrderDetailView(
                    order: order,
                    accentColor: selectedPOSAccentColor.color,
                    onAccept: {
                        selectedOnlineOrder = nil
                        pendingOnlineOrderAction = .accept(order)
                    },
                    onMarkPaid: {
                        selectedOnlineOrder = nil
                        pendingOnlineOrderAction = .markPaid(order)
                    },
                    onSendToKitchen: {
                        selectedOnlineOrder = nil
                        pendingOnlineOrderAction = .sendToKitchen(order)
                    },
                    onDecline: {
                        selectedOnlineOrder = nil
                        pendingOnlineOrderAction = .decline(order)
                    }
                )
                .presentationDetents([.large])
                .emberSheetChrome()
            }
            .sheet(item: $selectedCompletedTicket) { ticket in
                CompletedKitchenTicketDetailView(ticket: ticket, accentColor: selectedPOSAccentColor.color)
                    .environmentObject(printStore)
                    .presentationDetents([.medium, .large])
                    .emberSheetChrome()
            }
            .alert(
                pendingOnlineOrderAction?.title ?? "",
                isPresented: onlineOrderActionAlertBinding,
                presenting: pendingOnlineOrderAction
            ) { action in
                Button(action.confirmLabel, role: action.role) {
                    confirmOnlineOrderAction(action)
                }
                Button("Cancel", role: .cancel) {
                    pendingOnlineOrderAction = nil
                }
            } message: { action in
                Text(action.message)
            }
            .alert(
                "Cancel kitchen order?",
                isPresented: kitchenCancelAlertBinding,
                presenting: pendingKitchenCancelOrder
            ) { order in
                Button("Cancel order", role: .destructive) {
                    confirmKitchenCancelOrder(order)
                }
                Button("Keep order", role: .cancel) {
                    pendingKitchenCancelOrder = nil
                }
            } message: { order in
                Text("Are you sure you want to cancel \(order.orderNumber)? This removes it from the active kitchen rail.")
            }
            .sheet(isPresented: settingsSheetBinding) {
                SettingsView(store: store, posStore: posStore, printStore: printStore)
                    .presentationDetents([.large])
                    .emberSheetChrome()
            }
            .sheet(isPresented: $isPOSKeySetupOpen) {
                SettingsView(store: store, posStore: posStore, printStore: printStore, isConnectionOnly: true) {
                    isPOSKeySetupOpen = false
                    posStore.pinErrorMessage = nil
                }
                .presentationDetents([.large])
                .emberSheetChrome()
            }
            .sheet(isPresented: $isPOSCheckoutOpen) {
                POSCheckoutSheet(
                    lines: posStore.cartLines,
                    tickets: posStore.tickets,
                    activeTicketID: posStore.activeTicketID,
                    total: posStore.cartTotal,
                    baseURL: store.baseURL,
                    token: store.kitchenToken,
                    posSessionToken: posStaffSessionToken,
                    isSubmitting: posStore.isSubmitting,
                    accentColor: selectedPOSAccentColor.color,
                    toppingCategoryOrder: posToppingCategoryOrderRaw.csvValues,
                    productImageURL: { product in
                        posStore.imageURL(for: product)
                    },
                    onIncrement: { line in
                        posStore.increment(line: line)
                    },
                    onDecrement: { line in
                        posStore.decrement(line: line)
                    },
                    onRemove: { line in
                        posStore.remove(line: line)
                    },
                    onClearCart: {
                        posStore.clearCart()
                    },
                    onNewTicket: {
                        posStore.createNewTicket()
                    },
                    onSwitchTicket: { ticket in
                        posStore.switchTicket(ticket)
                    },
                    defaultPrintReceipt: { source in
                        printStore.enabledSources.allows(source.receiptSourceKey)
                    },
                    printQuotation: { snapshot in
                        await printStore.printQuotation(snapshot)
                    },
                    activeRewardRedemption: posStore.activeRewardRedemption,
                    activeRewardQuote: posStore.activeRewardQuote,
                    submissionError: posStore.errorMessage,
                    onMarketplacePriceChange: { line, price in
                        posStore.setMarketplaceUnitPrice(line: line, price: price)
                    },
                    onToppingsChange: { line, toppings in
                        posStore.updateToppings(line: line, toppings: toppings)
                    },
                    scanRewardToken: { token in
                        try await posStore.scanRewardToken(baseURL: store.baseURL, token: store.kitchenToken, rawToken: token)
                    },
                    quoteRewardSale: { paymentMethod, source, reference, customer, discountPercent, notes, rewardLineKey in
                        try await posStore.quoteRewardSale(
                            baseURL: store.baseURL,
                            token: store.kitchenToken,
                            paymentMethod: paymentMethod,
                            orderSource: source,
                            externalReference: reference,
                            customer: customer,
                            discountPercent: discountPercent,
                            notes: notes,
                            rewardLineKey: rewardLineKey
                        )
                    },
                    clearRewardRedemption: {
                        posStore.clearRewardRedemption()
                    },
                    clearRewardQuote: {
                        posStore.clearRewardQuote()
                    },
                    submit: { paymentMethod, source, reference, customer, discountPercent, notes, completionTotal, shouldPrintReceipt, rewardRedemptionSessionID, rewardLineKey in
                        guard let response = await posStore.submitSale(
                            baseURL: store.baseURL,
                            token: store.kitchenToken,
                            paymentMethod: paymentMethod,
                            orderSource: source,
                            externalReference: reference,
                            customer: customer,
                            discountPercent: discountPercent,
                            notes: notes,
                            completionTotal: completionTotal,
                            shouldPrintReceipt: shouldPrintReceipt,
                            rewardRedemptionSessionID: rewardRedemptionSessionID,
                            rewardLineKey: rewardLineKey,
                            onSyncedSale: { response, queuedSale in
                                await handleSyncedPOSSale(response, queuedSale: queuedSale)
                            }
                        ) else {
                            return false
                        }

                        guard response.saleID > 0 else {
                            return true
                        }

                        printStore.setPrintIntent(saleID: response.saleID, shouldPrint: shouldPrintReceipt)
                        var printResult = PrintReceiptResult.skipped
                        if shouldPrintReceipt {
                            printResult = await printStore.printSaleReceiptNow(saleID: response.saleID)
                        }

                        showSaleCompletion(saleID: response.saleID, total: response.total ?? completionTotal, printResult: printResult)
                        return true
                    }
                )
                .emberSheetChrome()
            }
            .sheet(isPresented: recapSheetBinding) {
                POSRecapSheet(
                    recap: posStore.recap,
                    isLoading: posStore.isRecapLoading,
                    errorMessage: posStore.recapErrorMessage,
                    accentColor: selectedPOSAccentColor.color
                ) {
                    Task { await posStore.refreshRecap(baseURL: store.baseURL, token: store.kitchenToken) }
                }
                .presentationDetents([.large])
                .emberSheetChrome()
            }
            .sheet(isPresented: shiftSheetBinding) {
                if let bootstrap = posStore.bootstrap {
                    POSShiftControlSheet(
                        operator: bootstrap.operator,
                        shift: bootstrap.shift,
                        isSubmitting: posStore.isShiftSubmitting,
                        accentColor: selectedPOSAccentColor.color,
                        onOpenShift: {
                            presentPOSStartShiftForm()
                        },
                        onCashIn: {
                            presentPOSCashMovementForm(.deposit)
                        },
                        onCashOut: {
                            presentPOSCashMovementForm(.withdrawal)
                        },
                        onCloseShift: {
                            presentPOSEndShiftForm()
                        },
                        onSignOff: {
                            resetPOSStaffSessionToPIN()
                        }
                    )
                    .presentationDetents([.large])
                    .emberSheetChrome()
                } else {
                    POSShiftLoadingSheet(accentColor: selectedPOSAccentColor.color)
                        .presentationDetents([.large])
                        .emberSheetChrome()
                }
            }
            .sheet(isPresented: $isPOSStartShiftOpen) {
                POSStartShiftSheet(
                    isSubmitting: posStore.isShiftSubmitting,
                    errorMessage: posStore.errorMessage,
                    accentColor: selectedPOSAccentColor.color
                ) { openingCash, notes in
                    guard await ensurePOSStaffSession() else { return false }
                    let didOpen = await posStore.startShift(baseURL: store.baseURL, token: store.kitchenToken, openingCash: openingCash, notes: notes)
                    if didOpen {
                        selectedSection = .pos
                        selectedCompactTab = .pos
                        isPOSShiftMenuOpen = false
                    }
                    return didOpen
                }
                .emberSheetChrome()
            }
            .sheet(item: $posCashMovementType) { type in
                POSCashMovementSheet(
                    type: type,
                    isSubmitting: posStore.isShiftSubmitting,
                    errorMessage: posStore.errorMessage,
                    accentColor: selectedPOSAccentColor.color
                ) { amount, reason in
                    guard await ensurePOSStaffSession() else { return false }
                    return await posStore.recordCashMovement(baseURL: store.baseURL, token: store.kitchenToken, type: type, amount: amount, reason: reason)
                }
                .emberSheetChrome()
            }
            .sheet(isPresented: $isPOSEndShiftOpen) {
                POSEndShiftSheet(
                    isSubmitting: posStore.isShiftSubmitting,
                    errorMessage: posStore.errorMessage,
                    accentColor: selectedPOSAccentColor.color,
                    loadShift: {
                        guard await ensurePOSStaffSession() else { return nil }
                        return await posStore.prepareShiftClosing(baseURL: store.baseURL, token: store.kitchenToken)
                    }
                ) { closingCash, notes in
                    guard await ensurePOSStaffSession() else { return false }
                    let didClose = await posStore.endShift(baseURL: store.baseURL, token: store.kitchenToken, closingCash: closingCash, notes: notes)
                    if didClose {
                        resetPOSStaffSessionToPIN()
                    }
                    return didClose
                }
                .emberSheetChrome()
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if !showsSplash {
                isSplashVisible = false
            }
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

    private func finishPOSArrangeMode() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPOSArrangeMode = false
        }
    }
}

private enum OnlineOrderAction: Identifiable {
    case accept(KitchenOnlineOrder)
    case markPaid(KitchenOnlineOrder)
    case sendToKitchen(KitchenOnlineOrder)
    case decline(KitchenOnlineOrder)

    var id: String {
        switch self {
        case .accept(let order):
            return "accept-\(order.id)"
        case .markPaid(let order):
            return "paid-\(order.id)"
        case .sendToKitchen(let order):
            return "send-\(order.id)"
        case .decline(let order):
            return "decline-\(order.id)"
        }
    }

    var title: String {
        switch self {
        case .accept:
            return "Accept online order?"
        case .markPaid:
            return "Confirm QR payment?"
        case .sendToKitchen:
            return "Send to Kitchen?"
        case .decline:
            return "Declining Online Order"
        }
    }

    var message: String {
        switch self {
        case .accept(let order):
            return "Accept \(order.orderNumber)? The customer will be notified and asked to complete payment if needed."
        case .markPaid(let order):
            return "Mark QR payment received for \(order.orderNumber)?"
        case .sendToKitchen(let order):
            if order.paymentMethod == "pay_at_counter" {
                return "Confirm cash collected for \(order.orderNumber)? Sending to Kitchen records this payment in the open cash drawer."
            }
            return "Send \(order.orderNumber) into the kitchen queue now?"
        case .decline(let order):
            return "Are you sure you want to decline the order \(order.orderNumber)?"
        }
    }

    var confirmLabel: String {
        switch self {
        case .accept:
            return "Accept"
        case .markPaid:
            return "Mark Paid"
        case .sendToKitchen:
            return "Send"
        case .decline:
            return "Decline"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .accept, .markPaid, .sendToKitchen:
            return nil
        case .decline:
            return .destructive
        }
    }
}

@MainActor
final class PrintBridgeStore: ObservableObject {
    @Published private(set) var isReprintingReceipt = false
    @Published var serverURL = UserDefaults.standard.string(forKey: "PrintBridgeServerURL") ?? "https://app.fitbites.com.vn"
    @Published var printToken = UserDefaults.standard.string(forKey: "PrintBridgeToken") ?? ""
    @Published var printerHost = UserDefaults.standard.string(forKey: "PrintBridgePrinterHost") ?? "192.168.1.92"
    @Published var printerPort = UserDefaults.standard.integer(forKey: "PrintBridgePrinterPort") == 0
        ? 9100
        : UserDefaults.standard.integer(forKey: "PrintBridgePrinterPort")
    @Published var paperWidth = UserDefaults.standard.integer(forKey: "PrintBridgePaperWidth") == 0
        ? 80
        : UserDefaults.standard.integer(forKey: "PrintBridgePaperWidth")
    @Published var autoPrint = UserDefaults.standard.bool(forKey: "PrintBridgeAutoPrint")
    @Published var enabledSources = PrintSourceSelection.load()
    @Published var isConnected = false
    @Published var isPrinting = false
    @Published var statusMessage = "Printer not checked yet."
    var receiptLogoURL: URL?
    var receiptLogoScale = 1.0

    private var pollTimer: Timer?
    private var isPollInFlight = false
    private var autoPrintArmedAt = UserDefaults.standard.object(forKey: "PrintBridgeAutoPrintArmedAt") as? Date ?? Date()
    private var skippedSaleIDs = Set(UserDefaults.standard.array(forKey: "PrintBridgeSkippedSaleIDs") as? [Int] ?? [])
    private var allowedSaleIDs = Set(UserDefaults.standard.array(forKey: "PrintBridgeAllowedSaleIDs") as? [Int] ?? [])

    func saveSettings(
        serverURL: String,
        token: String,
        host: String,
        port: Int,
        paperWidth: Int,
        autoPrint: Bool,
        enabledSources: PrintSourceSelection
    ) {
        let isTurningAutoPrintOn = !self.autoPrint && autoPrint
        self.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.printToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.printerHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.printerPort = max(1, port)
        self.paperWidth = paperWidth == 58 ? 58 : 80
        self.autoPrint = autoPrint
        self.enabledSources = enabledSources

        if isTurningAutoPrintOn {
            autoPrintArmedAt = Date()
            UserDefaults.standard.set(autoPrintArmedAt, forKey: "PrintBridgeAutoPrintArmedAt")
        }

        UserDefaults.standard.set(self.serverURL, forKey: "PrintBridgeServerURL")
        UserDefaults.standard.set(self.printToken, forKey: "PrintBridgeToken")
        UserDefaults.standard.set(self.printerHost, forKey: "PrintBridgePrinterHost")
        UserDefaults.standard.set(self.printerPort, forKey: "PrintBridgePrinterPort")
        UserDefaults.standard.set(self.paperWidth, forKey: "PrintBridgePaperWidth")
        UserDefaults.standard.set(self.autoPrint, forKey: "PrintBridgeAutoPrint")
        self.enabledSources.save()

        statusMessage = self.autoPrint ? "Auto-print ready for new receipts." : "Auto-print off."
        start()
    }

    func start() {
        pollTimer?.invalidate()

        guard autoPrint else {
            isConnected = false
            return
        }

        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollOnce()
            }
        }

        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task { await pollOnce() }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isPollInFlight = false
    }

    func printTestReceipt() async {
        guard validateSettings() else { return }

        isPrinting = true
        statusMessage = "Sending test receipt..."

        do {
            let receipt = PrintReceiptFormatter.testReceipt()
            let data = PrintReceiptFormatter.format(receipt, paperWidth: paperWidth, logoURL: receiptLogoURL, logoScale: receiptLogoScale)
            try await NetworkReceiptPrinter(host: printerHost, port: printerPort).print(data)
            isConnected = true
            statusMessage = "Test receipt sent."
            Haptics.notification(.success)
        } catch {
            isConnected = false
            statusMessage = error.localizedDescription
            Haptics.notification(.error)
        }

        isPrinting = false
    }

    func setPrintIntent(saleID: Int, shouldPrint: Bool) {
        if shouldPrint {
            skippedSaleIDs.remove(saleID)
            allowedSaleIDs.insert(saleID)
        } else {
            allowedSaleIDs.remove(saleID)
            skippedSaleIDs.insert(saleID)
        }

        UserDefaults.standard.set(Array(skippedSaleIDs), forKey: "PrintBridgeSkippedSaleIDs")
        UserDefaults.standard.set(Array(allowedSaleIDs), forKey: "PrintBridgeAllowedSaleIDs")
    }

    fileprivate func printQuotation(_ snapshot: POSQuotationSnapshot) async -> PrintReceiptResult {
        guard !snapshot.items.isEmpty else { return .failed("The cart is empty.") }
        guard !printerHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65535).contains(printerPort) else {
            return .failed("Check the printer IP and port in Settings.")
        }

        // A quotation has no server print job or sale identity. Do not update receipt state.
        do {
            let data = try PrintReceiptFormatter.formatQuotation(snapshot, paperWidth: paperWidth, logoURL: receiptLogoURL, logoScale: receiptLogoScale)
            try await NetworkReceiptPrinter(host: printerHost, port: printerPort).print(data)
            return .printed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    fileprivate func reprintSaleReceipt(saleID: Int) async -> PrintReceiptResult {
        guard !isReprintingReceipt else { return .failed("A receipt copy is already printing.") }
        guard validateSettings() else { return .failed(statusMessage) }
        guard (1...65535).contains(printerPort) else { return .failed("Check the printer port in Settings.") }
        isReprintingReceipt = true
        defer { isReprintingReceipt = false }

        do {
            // Read an existing receipt without claiming, retrying, or completing a print job.
            let response = try await PrintJobAPIClient(baseURL: serverURL, token: printToken).fetchReceipt(saleID: saleID)
            guard response.payload.receipt.saleID == saleID else { return .failed("The receipt does not match this sale.") }
            let data = PrintReceiptFormatter.format(response.payload, paperWidth: paperWidth, logoURL: receiptLogoURL, logoScale: receiptLogoScale)
            try await NetworkReceiptPrinter(host: printerHost, port: printerPort).print(data)
            return .printed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    fileprivate func printSaleReceiptNow(saleID: Int) async -> PrintReceiptResult {
        guard validateSettings() else { return .failed(statusMessage) }

        isPrinting = true
        statusMessage = "Printing sale #\(saleID)..."
        defer { isPrinting = false }

        do {
            let client = PrintJobAPIClient(baseURL: serverURL, token: printToken)
            let lookup = try await client.fetchPendingJobWithRetry(saleID: saleID)

            guard let job = lookup.job else {
                isConnected = true
                statusMessage = "Sale saved. No receipt job found yet."
                return .failed("No receipt job found yet.")
            }

            let claimed = try await client.claim(jobID: job.id, bridgeName: "emberos-ipad-manual")
            let data = PrintReceiptFormatter.format(claimed.job.payload, paperWidth: paperWidth, logoURL: receiptLogoURL, logoScale: receiptLogoScale)
            try await NetworkReceiptPrinter(host: printerHost, port: printerPort).print(data)
            _ = try await client.markPrinted(jobID: job.id)
            allowedSaleIDs.remove(saleID)
            skippedSaleIDs.remove(saleID)
            UserDefaults.standard.set(Array(skippedSaleIDs), forKey: "PrintBridgeSkippedSaleIDs")
            UserDefaults.standard.set(Array(allowedSaleIDs), forKey: "PrintBridgeAllowedSaleIDs")
            isConnected = true
            statusMessage = "Printed sale #\(saleID)."
            Haptics.notification(.success)
            return .printed
        } catch {
            isConnected = false
            statusMessage = error.localizedDescription
            Haptics.notification(.error)
            return .failed(error.localizedDescription)
        }
    }

    func pollOnce() async {
        guard autoPrint, validateSettings(silent: true), !isPollInFlight else {
            return
        }

        isPollInFlight = true
        isPrinting = true

        do {
            let client = PrintJobAPIClient(baseURL: serverURL, token: printToken)
            let pending = try await client.fetchPendingJobs().jobs
            let printableJobs = pending.filter { job in
                guard let createdAt = job.createdAt else {
                    return false
                }

                guard createdAt >= autoPrintArmedAt else {
                    return false
                }

                if let saleID = job.saleID {
                    if skippedSaleIDs.contains(saleID) {
                        return false
                    }

                    if allowedSaleIDs.contains(saleID) {
                        return true
                    }
                }

                return enabledSources.allows(job.payload.receipt.orderSource)
            }

            guard let job = printableJobs.first else {
                isConnected = true
                statusMessage = pending.isEmpty
                    ? "No receipt waiting."
                    : "No selected source waiting."
                isPrinting = false
                isPollInFlight = false
                return
            }

            let claimed = try await client.claim(jobID: job.id, bridgeName: "emberos-ipad")
            let data = PrintReceiptFormatter.format(claimed.job.payload, paperWidth: paperWidth, logoURL: receiptLogoURL, logoScale: receiptLogoScale)
            try await NetworkReceiptPrinter(host: printerHost, port: printerPort).print(data)
            _ = try await client.markPrinted(jobID: job.id)
            if let saleID = job.saleID {
                allowedSaleIDs.remove(saleID)
                skippedSaleIDs.remove(saleID)
                UserDefaults.standard.set(Array(skippedSaleIDs), forKey: "PrintBridgeSkippedSaleIDs")
                UserDefaults.standard.set(Array(allowedSaleIDs), forKey: "PrintBridgeAllowedSaleIDs")
            }
            isConnected = true
            statusMessage = "Printed receipt #\(job.id)."
        } catch {
            isConnected = false
            statusMessage = error.localizedDescription
        }

        isPrinting = false
        isPollInFlight = false
    }

    private func validateSettings(silent: Bool = false) -> Bool {
        let isValid = !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !printToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !printerHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !isValid, !silent {
            statusMessage = "Add server, print key, and printer IP."
            Haptics.notification(.error)
        }

        return isValid
    }
}

struct PrintJobAPIClient {
    let baseURL: String
    let token: String

    func fetchReceipt(saleID: Int) async throws -> PrintReceiptCopyResponse {
        try await request(path: "/api/print-jobs/sale/\(saleID)/receipt", method: "GET", body: Optional<PrintClaimRequest>.none)
    }

    func fetchPendingJobs() async throws -> PrintJobsResponse {
        try await request(path: "/api/print-jobs/pending", method: "GET", body: Optional<PrintClaimRequest>.none)
    }

    func claim(jobID: Int, bridgeName: String) async throws -> PrintJobResponse {
        try await request(path: "/api/print-jobs/\(jobID)/claim", method: "POST", body: PrintClaimRequest(claimedBy: bridgeName))
    }

    func markPrinted(jobID: Int) async throws -> PrintJobResponse {
        try await request(path: "/api/print-jobs/\(jobID)/printed", method: "POST", body: Optional<PrintClaimRequest>.none)
    }

    func fetchPendingJob(saleID: Int) async throws -> PrintJobLookupResponse {
        try await request(path: "/api/print-jobs/sale/\(saleID)/pending", method: "GET", body: Optional<PrintClaimRequest>.none)
    }

    func fetchPendingJobWithRetry(saleID: Int) async throws -> PrintJobLookupResponse {
        var latestLookup = try await fetchPendingJob(saleID: saleID)
        guard latestLookup.job == nil else {
            return latestLookup
        }

        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 450_000_000)
            latestLookup = try await fetchPendingJob(saleID: saleID)
            if latestLookup.job != nil {
                return latestLookup
            }
        }

        return latestLookup
    }

    private func request<Response: Decodable, Body: Encodable>(path: String, method: String, body: Body?) async throws -> Response {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw KitchenAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KitchenAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let body = String(data: data, encoding: .utf8) {
                print("Kitchen API \(httpResponse.statusCode) at \(path): \(body)")
            }

            if httpResponse.statusCode == 403 {
                throw KitchenAPIError.unauthorized
            }

            throw KitchenAPIError.server(httpResponse.statusCode, path)
        }

        return try JSONDecoder.kitchen.decode(Response.self, from: data)
    }
}

struct NetworkReceiptPrinter {
    let host: String
    let port: Int

    func print(_ data: Data) async throws {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 9100,
            using: .tcp
        )

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var didResume = false

                func resume(_ result: Result<Void, Error>) {
                    guard !didResume else { return }
                    didResume = true
                    connection.cancel()
                    continuation.resume(with: result)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error {
                                resume(.failure(error))
                            } else {
                                resume(.success(()))
                            }
                        })
                    case .failed(let error):
                        resume(.failure(error))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }

                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

struct POSQuotationSnapshot {
    typealias Item = PrintReceiptItem

    let createdAt = Date()
    let items: [Item]
    let subtotal: Double
    let discount: Double
    let marketplaceDeduction: Double
    let rewardDiscount: Double
    let total: Double
}

enum PrintReceiptFormatter {
    private static let esc = UInt8(0x1b)
    private static let gs = UInt8(0x1d)
    private static let lf = UInt8(0x0a)

    static func formatQuotation(_ snapshot: POSQuotationSnapshot, paperWidth: Int, logoURL: URL? = nil, logoScale: Double = 1) throws -> Data {
        let columns = paperWidth == 58 ? 32 : 48
        var data = Data()
        append(&data, [esc, 0x40])
        alignCenter(&data)
        if !appendLogoIfAvailable(&data, logoURL: logoURL, paperWidth: paperWidth, logoScale: logoScale) {
            bold(&data, true)
            appendLine(&data, "FITBITES")
            bold(&data, false)
        }
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        timestamp.dateFormat = "HH:mm dd/MM/yyyy"
        appendLine(&data, timestamp.string(from: snapshot.createdAt))
        bold(&data, true)
        appendLine(&data, "For Order Review Only")
        bold(&data, false)
        alignLeft(&data)
        divider(&data, columns: columns)
        for item in snapshot.items {
            wrappedAmountLines("\(item.quantity) x \(item.name)", amount: money(item.baseLineTotal), columns: columns)
                .forEach { appendLine(&data, $0) }
            for topping in item.toppings {
                wrappedAmountLines("   + \(topping.name)", amount: money(topping.lineTotal), columns: columns)
                    .forEach { appendLine(&data, $0) }
            }
            blank(&data)
        }
        divider(&data, columns: columns)
        appendLine(&data, pair("Subtotal", money(snapshot.subtotal), columns: columns))
        if snapshot.discount > 0 {
            appendLine(&data, pair("Discount", "-\(money(snapshot.discount))", columns: columns))
        }
        if snapshot.marketplaceDeduction > 0 {
            appendLine(&data, pair("Grab/Shopee deduction", "-\(money(snapshot.marketplaceDeduction))", columns: columns))
        }
        if snapshot.rewardDiscount > 0 {
            appendLine(&data, pair("Free Fitbites", "-\(money(snapshot.rewardDiscount))", columns: columns))
        }
        divider(&data, columns: columns)
        bold(&data, true)
        appendLine(&data, pair("TOTAL", money(snapshot.total), columns: columns))
        bold(&data, false)
        alignCenter(&data)
        appendLine(&data, "Not proof of payment.")
        blank(&data)
        blank(&data)
        append(&data, [gs, 0x56, 0x42, 0x00])
        return data
    }

    static func format(_ payload: PrintReceiptPayload, paperWidth: Int, logoURL: URL? = nil, logoScale: Double = 1) -> Data {
        let columns = paperWidth == 58 ? 32 : 48
        var data = Data()

        append(&data, [esc, 0x40])
        alignCenter(&data)

        if !appendLogoIfAvailable(&data, logoURL: logoURL, paperWidth: paperWidth, logoScale: logoScale) {
            bold(&data, true)
            appendLine(&data, payload.store.name.uppercased())
            bold(&data, false)
        }

        appendLine(&data, "Health has never tasted this wrong.")
        appendLine(&data, payload.store.address)
        blank(&data)
        divider(&data, columns: columns, character: "=")
        alignLeft(&data)
        appendLine(&data, pair("Receipt no.", payload.receipt.number, columns: columns))
        appendLine(&data, pair("Date / time", formattedDate(payload.receipt.date), columns: columns))
        appendLine(&data, pair("Cashier", payload.receipt.cashier ?? "-", columns: columns))
        appendLine(&data, pair("Payment", payload.receipt.paymentMethod.humanized, columns: columns))
        divider(&data, columns: columns, character: "=")
        blank(&data)

        for item in payload.items {
            wrappedAmountLines("\(item.quantity) x \(item.name)", amount: money(item.baseLineTotal), columns: columns).forEach {
                appendLine(&data, $0)
            }

            for topping in item.toppings {
                wrappedAmountLines("   + \(topping.name)", amount: money(topping.lineTotal), columns: columns).forEach {
                    appendLine(&data, $0)
                }
            }

            blank(&data)
        }

        divider(&data, columns: columns)
        appendLine(&data, pair("Subtotal", money(payload.totals.subtotal), columns: columns))

        if payload.totals.discount > 0 {
            appendLine(&data, pair("Discount", "-\(money(payload.totals.discount))", columns: columns))
        }

        if payload.totals.deliveryFee > 0 {
            appendLine(&data, pair("Delivery", money(payload.totals.deliveryFee), columns: columns))
        }

        divider(&data, columns: columns)
        bold(&data, true)
        appendLine(&data, pair("TOTAL", money(payload.totals.total), columns: columns))
        bold(&data, false)

        if let customer = payload.customer, customer.name != nil || customer.phone != nil {
            divider(&data, columns: columns)
            appendLine(&data, "Customer: \(customer.name ?? "-")")
            if let phone = customer.phone {
                appendLine(&data, "Phone: \(phone)")
            }
        }

        if let loyalty = payload.loyalty {
            divider(&data, columns: columns)
            appendLine(&data, "Fitbites loyalty")
            appendLine(&data, pair("Stamps", "\(loyalty.safeStamps) / \(loyalty.safeTarget)", columns: columns))
            appendLine(&data, loyalty.receiptStarsLine)
            appendLine(&data, pair("Level", "\(loyalty.level) - \(loyalty.xp) XP", columns: columns))
            if loyalty.rewardCount > 0 {
                appendLine(&data, "\(loyalty.rewardCount) reward\(loyalty.rewardCount == 1 ? "" : "s") available")
            }
        }

        if let notes = payload.notes, !notes.isEmpty {
            divider(&data, columns: columns)
            wrap("Notes: \(notes)", columns: columns).forEach { appendLine(&data, $0) }
        }

        blank(&data)
        alignCenter(&data)
        divider(&data, columns: min(columns, 32))
        bold(&data, true)
        appendLine(&data, "Thank you, my Fitbites.")
        bold(&data, false)
        appendLine(&data, "See you soon.")
        blank(&data)
        blank(&data)
        append(&data, [gs, 0x56, 0x42, 0x00])

        return data
    }

    static func testReceipt() -> PrintReceiptPayload {
        PrintReceiptPayload(
            store: PrintReceiptStore(name: "Fitbites", address: "iPad printer test"),
            receipt: PrintReceiptInfo(
                number: "IPAD-TEST",
                saleID: nil,
                date: ISO8601DateFormatter().string(from: Date()),
                cashier: "emberOS iPad",
                paymentMethod: "test",
                orderSource: nil
            ),
            customer: nil,
            items: [
                PrintReceiptItem(
                    name: "Hello World. This is emberOS talking to you now.",
                    sku: nil,
                    category: nil,
                    quantity: 1,
                    baseUnitPrice: 0,
                    unitPrice: 0,
                    lineTotal: 0,
                    toppings: []
                ),
                PrintReceiptItem(
                    name: "Good news, a brand new iOS Fitbites app is coming.",
                    sku: nil,
                    category: nil,
                    quantity: 1,
                    baseUnitPrice: 0,
                    unitPrice: 0,
                    lineTotal: 0,
                    toppings: []
                ),
                PrintReceiptItem(
                    name: "Be ready.",
                    sku: nil,
                    category: nil,
                    quantity: 1,
                    baseUnitPrice: 0,
                    unitPrice: 0,
                    lineTotal: 0,
                    toppings: []
                ),
            ],
            totals: PrintReceiptTotals(subtotal: 0, discount: 0, discountPercent: 0, deliveryFee: 0, total: 0),
            notes: nil,
            loyalty: PrintReceiptLoyalty(level: 1, xp: 0, stamps: 3, target: 9, rewardCount: 0)
        )
    }

    private static func append(_ data: inout Data, _ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    private static func appendLogoIfAvailable(_ data: inout Data, logoURL: URL?, paperWidth: Int, logoScale: Double) -> Bool {
        let image: UIImage?
        if let logoURL, logoURL.isFileURL {
            image = UIImage(contentsOfFile: logoURL.path)
        } else {
            image = UIImage(named: "EmberOSLogo")
        }

        guard let image else {
            return false
        }

        let printableImage = image.croppedToVisiblePixels(whiteThreshold: 236) ?? image
        let basePixelWidth = paperWidth == 58 ? 185 : 315
        let printablePixelWidth = paperWidth == 58 ? 252 : 364
        let clampedScale = min(max(logoScale, 0.6), 1.15)
        let maxPixelWidth = min(printablePixelWidth, Int(Double(basePixelWidth) * clampedScale))
        guard let raster = escposRasterImageData(for: printableImage, maxPixelWidth: maxPixelWidth) else {
            return false
        }

        append(&data, raster)
        return true
    }

    private static func escposRasterImageData(for image: UIImage, maxPixelWidth: Int) -> [UInt8]? {
        guard let prepared = prepareReceiptLogo(image, maxPixelWidth: maxPixelWidth),
              let cgImage = prepared.cgImage,
              let provider = cgImage.dataProvider,
              let pixelData = provider.data,
              let bytes = CFDataGetBytePtr(pixelData) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = cgImage.bytesPerRow
        let bitmapBytesPerRow = (width + 7) / 8
        var imageBytes = [UInt8](repeating: 0, count: bitmapBytesPerRow * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let red = Double(bytes[offset])
                let green = Double(bytes[offset + 1])
                let blue = Double(bytes[offset + 2])
                let alpha = Double(bytes[offset + 3]) / 255.0
                let luminance = (0.299 * red + 0.587 * green + 0.114 * blue) * alpha + 255.0 * (1.0 - alpha)

                if luminance < 178 {
                    let byteIndex = y * bitmapBytesPerRow + x / 8
                    imageBytes[byteIndex] |= UInt8(0x80 >> (x % 8))
                }
            }
        }

        let xL = UInt8(bitmapBytesPerRow & 0xff)
        let xH = UInt8((bitmapBytesPerRow >> 8) & 0xff)
        let yL = UInt8(height & 0xff)
        let yH = UInt8((height >> 8) & 0xff)
        return [gs, 0x76, 0x30, 0x00, xL, xH, yL, yH] + imageBytes + [lf]
    }

    private static func prepareReceiptLogo(_ image: UIImage, maxPixelWidth: Int) -> UIImage? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let maxPixelHeight: CGFloat = maxPixelWidth <= 252 ? 68 : 88
        let scale = min(CGFloat(maxPixelWidth) / sourceSize.width, maxPixelHeight / sourceSize.height)
        let canvasSize = CGSize(width: ceil(sourceSize.width * scale), height: ceil(sourceSize.height * scale))

        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            image.draw(in: CGRect(origin: .zero, size: canvasSize))
        }
    }

    private static func appendLine(_ data: inout Data, _ text: String) {
        data.append(Data(printerText(text).utf8))
        data.append(lf)
    }

    private static func blank(_ data: inout Data) {
        appendLine(&data, "")
    }

    private static func alignLeft(_ data: inout Data) {
        append(&data, [esc, 0x61, 0x00])
    }

    private static func alignCenter(_ data: inout Data) {
        append(&data, [esc, 0x61, 0x01])
    }

    private static func bold(_ data: inout Data, _ isOn: Bool) {
        append(&data, [esc, 0x45, isOn ? 0x01 : 0x00])
    }

    private static func divider(_ data: inout Data, columns: Int, character: Character = "-") {
        appendLine(&data, String(repeating: String(character), count: columns))
    }

    private static func pair(_ left: String, _ right: String, columns: Int) -> String {
        let leftText = printerText(left)
        let rightText = printerText(right)
        let spaces = max(1, columns - leftText.count - rightText.count)
        return leftText + String(repeating: " ", count: spaces) + rightText
    }

    private static func wrappedAmountLines(_ left: String, amount: String, columns: Int) -> [String] {
        let amountWidth = amount.count
        let textWidth = max(8, columns - amountWidth - 1)
        let wrapped = wrap(left, columns: textWidth)

        guard let first = wrapped.first else {
            return [pair(left, amount, columns: columns)]
        }

        return [pair(first, amount, columns: columns)] + wrapped.dropFirst()
    }

    private static func wrap(_ value: String, columns: Int) -> [String] {
        let words = printerText(value).split(separator: " ").map(String.init)
        var lines: [String] = []
        var current = ""

        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= columns {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines.isEmpty ? [""] : lines
    }

    private static func money(_ value: Double) -> String {
        "\(Int(value).formatted()) VND"
    }

    private static func formattedDate(_ value: String?) -> String {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else {
            return value ?? "-"
        }

        return date.formatted(date: .numeric, time: .shortened)
    }

    private static func printerText(_ value: String) -> String {
        value
            .folding(options: .diacriticInsensitive, locale: .current)
            .unicodeScalars
            .filter { scalar in
                scalar.isASCII && scalar.value >= 0x20 && scalar.value <= 0x7e
            }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

struct PrintSourceSelection: Equatable {
    var store: Bool = true
    var website: Bool = true
    var grab: Bool = false
    var shopee: Bool = false

    static func load() -> PrintSourceSelection {
        if UserDefaults.standard.object(forKey: "PrintSourceStore") == nil {
            return PrintSourceSelection()
        }

        return PrintSourceSelection(
            store: UserDefaults.standard.bool(forKey: "PrintSourceStore"),
            website: UserDefaults.standard.bool(forKey: "PrintSourceWebsite"),
            grab: UserDefaults.standard.bool(forKey: "PrintSourceGrab"),
            shopee: UserDefaults.standard.bool(forKey: "PrintSourceShopee")
        )
    }

    func save() {
        UserDefaults.standard.set(store, forKey: "PrintSourceStore")
        UserDefaults.standard.set(website, forKey: "PrintSourceWebsite")
        UserDefaults.standard.set(grab, forKey: "PrintSourceGrab")
        UserDefaults.standard.set(shopee, forKey: "PrintSourceShopee")
    }

    func allows(_ source: String?) -> Bool {
        switch (source ?? "pos").lowercased() {
        case "pos", "store", "in_store":
            return store
        case "online_in_store", "online_pickup", "online_delivery", "website":
            return website
        case "grabfood", "grab":
            return grab
        case "shopeefood", "shopee":
            return shopee
        default:
            return store
        }
    }
}

private enum KitchenConnectionDefaults {
    static let productionBaseURL = "https://fitbites.com.vn"

    static func savedBaseURL() -> String {
        normalizedBaseURL(UserDefaults.standard.string(forKey: "KitchenBaseURL") ?? productionBaseURL)
    }

    static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return productionBaseURL }
        guard !isLocalDevelopmentURL(trimmed) else { return productionBaseURL }
        if var components = URLComponents(string: trimmed), components.host?.lowercased() == "app.fitbites.com.vn" {
            components.scheme = "https"
            components.host = "fitbites.com.vn"
            return components.string ?? productionBaseURL
        }
        return trimmed
    }

    private static func isLocalDevelopmentURL(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("127.0.0.1")
            || lowercased.contains("localhost")
            || lowercased.contains("0.0.0.0")
    }
}

@MainActor
final class KitchenStore: ObservableObject {
    @Published var onlineOrders: [KitchenOnlineOrder] = []
    @Published var orders: [KitchenOrder] = []
    @Published var completedTickets: [CompletedKitchenTicket] = CompletedKitchenTicketStore.load()
    @Published var onlineOrderDetailsBySaleID: [Int: KitchenOnlineOrder] = [:]
    @Published var summary = KitchenSummary.empty
    @Published var isInitialLoading = false
    @Published var isRefreshing = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var notificationMessage: String?
    @Published var baseURL = KitchenConnectionDefaults.savedBaseURL()
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
        pruneCompletedTickets()

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
        self.baseURL = KitchenConnectionDefaults.normalizedBaseURL(baseURL)
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
        defer {
            isRefreshInFlight = false
        }

        await performRefresh(forceChime: forceChime)
    }

    func refreshAfterExternalSaleMutation(baseURL: String, token: String) async {
        // A normal coalesced refresh may have started before the cancellation. Wait for it,
        // then perform a guaranteed post-mutation read for the cash drawer.
        await refreshTask?.value
        await performRefresh(baseURL: baseURL, token: token)
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

        defer {
            isInitialLoading = false
            isRefreshing = false
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
            let alertableKitchenOrderIDs = Set(
                kitchenPayload.orders
                    .filter { $0.source != .store && $0.status != .completed && $0.status != .cancelled }
                    .map(\.id)
            )
            let previousActiveCount = orders.count + onlineOrders.count
            let newOnlineIDs = incomingOnlineIDs.subtracting(knownOnlineOrderIDs)
            let newKitchenOrderIDs = alertableKitchenOrderIDs.subtracting(knownOrderIDs)
            let unalertedSubmittedIDs = submittedOnlineIDs.subtracting(alertedOnlineOrderIDs)
            let alertingIDs = Set(kitchenPayload.orders.filter(\.isPastAlertThreshold).map(\.id))
            let newAlertingIDs = alertingIDs.subtracting(alertingOrderIDs)
            let chimeOrderCount = unalertedSubmittedIDs.count

            onlineOrders = onlinePayload.onlineOrders
            orders = kitchenPayload.orders.filter { $0.status != .completed && $0.status != .cancelled }
            summary = kitchenPayload.summary
            pruneCompletedTickets()
            knownOrderIDs = incomingIDs
            knownOnlineOrderIDs = incomingOnlineIDs
            alertedOnlineOrderIDs.formIntersection(submittedOnlineIDs)
            alertingOrderIDs = alertingIDs
            errorMessage = nil
            isConnected = true
            hasLoadedOnce = true

            if chimeOrderCount > 0 {
                alertedOnlineOrderIDs.formUnion(unalertedSubmittedIDs)
                showNotification(
                    chimeOrderCount == 1
                        ? "You received a new order!"
                        : "You received \(chimeOrderCount) new orders!"
                )
                chime.play(tone: chimeTone)
            }

            if !firstLoad && (
                !newOnlineIDs.isEmpty ||
                !newKitchenOrderIDs.isEmpty ||
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
                    if updated.status == .completed {
                        archiveCompleted(updated)
                    }
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
            let response = try await KitchenAPIClient(baseURL: baseURL, token: kitchenToken).acceptOnlineOrder(order)
            upsertOnlineOrder(response.onlineOrder)
            await refresh(forceChime: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markOnlineOrderPaid(_ order: KitchenOnlineOrder) async {
        chime.stop()

        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: kitchenToken).markOnlineOrderPaid(order)
            upsertOnlineOrder(response.onlineOrder)
            await refresh(forceChime: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendOnlineOrderToKitchen(_ order: KitchenOnlineOrder) async {
        chime.stop()

        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: kitchenToken).sendOnlineOrderToKitchen(order)
            onlineOrders.removeAll { $0.id == order.id }
            onlineOrderDetailsBySaleID[response.sale.id] = response.onlineOrder
            knownOrderIDs.insert(response.sale.id)
            upsertKitchenOrder(response.sale)
            knownOnlineOrderIDs.remove(order.id)
            alertedOnlineOrderIDs.remove(order.id)
            await refresh(forceChime: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upsertOnlineOrder(_ order: KitchenOnlineOrder) {
        if let index = onlineOrders.firstIndex(where: { $0.id == order.id }) {
            onlineOrders[index] = order
        } else {
            onlineOrders.insert(order, at: 0)
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

    private func upsertKitchenOrder(_ order: KitchenOrder) {
        if order.status == .completed || order.status == .cancelled {
            orders.removeAll { $0.id == order.id }
            if order.status == .completed {
                archiveCompleted(order)
            }
            return
        }

        if let index = orders.firstIndex(where: { $0.id == order.id }) {
            orders[index] = order
        } else {
            orders.insert(order, at: 0)
        }

        summary = KitchenSummary(
            pending: orders.filter { $0.status == .pending }.count,
            preparing: orders.filter { $0.status == .preparing }.count,
            ready: orders.filter { $0.status == .ready }.count,
            held: orders.filter { $0.status == .held }.count
        )
    }

    private func archiveCompleted(_ order: KitchenOrder) {
        let ticket = CompletedKitchenTicket(
            order: order,
            onlineDetails: onlineOrderDetailsBySaleID[order.id],
            archivedAt: Date()
        )
        completedTickets.removeAll { $0.id == ticket.id }
        completedTickets.insert(ticket, at: 0)
        onlineOrderDetailsBySaleID.removeValue(forKey: order.id)
        pruneCompletedTickets()
        CompletedKitchenTicketStore.save(completedTickets)
    }

    private func pruneCompletedTickets() {
        let cutoff = CompletedKitchenTicketStore.vietnamStartOfToday()
        let pruned = completedTickets
            .filter { $0.archivedAt >= cutoff }
            .sorted { $0.archivedAt > $1.archivedAt }

        if pruned != completedTickets {
            completedTickets = pruned
            CompletedKitchenTicketStore.save(pruned)
        }
    }
}

@MainActor
final class POSStore: ObservableObject {
    @Published var bootstrap: POSBootstrapResponse?
    @Published var cartLines: [POSCartLine] = []
    @Published private(set) var tickets: [POSDraftTicket]
    @Published private(set) var activeTicketID: UUID
    @Published var isInitialLoading = false
    @Published var isRefreshing = false
    @Published var isSubmitting = false
    @Published var isShiftSubmitting = false
    @Published var isRecapLoading = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var pinErrorMessage: String?
    @Published var recapErrorMessage: String?
    @Published var saleMessage: String?
    @Published var recap: POSRecap?
    @Published var productImageOverrideURLs: [Int: URL] = [:]
    @Published var brandLogoOverrideURL: URL?
    @Published var isPinAuthenticating = false
    @Published var pendingSaleSyncCount = 0
    @Published var pendingShiftSyncCount = 0
    @Published var activeRewardRedemption: POSRewardRedemption?
    @Published var activeRewardQuote: POSRewardQuote?
    @Published private(set) var productQuantities: [Int: Int] = [:]

    private var refreshTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var saleMessageClearTask: Task<Void, Never>?
    private var saleSyncTask: Task<Void, Never>?
    private var shiftSyncTask: Task<Void, Never>?
    private var staffSessionToken = ""
    private var rewardCheckoutToken: String?
    private var rewardQuoteRevision = UUID()
    private let imageOverridesDirectoryName = "POSProductImageOverrides"
    private let brandLogoFileName = "pos-brand-logo.png"
    private var nextTicketNumber = 1

    init() {
        if let snapshot = POSDraftTicketStore.load(), !snapshot.tickets.isEmpty {
            tickets = snapshot.tickets
            activeTicketID = snapshot.tickets.contains(where: { $0.id == snapshot.activeTicketID })
                ? snapshot.activeTicketID
                : snapshot.tickets[0].id
            cartLines = snapshot.tickets.first(where: { $0.id == activeTicketID })?.lines ?? []
            nextTicketNumber = max(snapshot.nextTicketNumber, snapshot.tickets.map(\.number).max() ?? 1)
        } else {
            let firstTicket = POSDraftTicket(number: 1)
            tickets = [firstTicket]
            activeTicketID = firstTicket.id
        }
        loadProductImageOverrides()
        loadBrandLogoOverride()
        loadCachedBootstrapIfAvailable()
        pendingSaleSyncCount = POSQueuedSaleStore.load().count
        pendingShiftSyncCount = POSQueuedShiftMutationStore.load().count
        rebuildProductQuantities()
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

    var openTicketCount: Int {
        tickets.filter { !$0.lines.isEmpty || $0.id == activeTicketID }.count
    }

    var cartTotal: Double {
        cartLines.reduce(0) { $0 + $1.lineTotal }
    }

    var hasOpenShiftForCurrentOperator: Bool {
        guard let bootstrap,
              bootstrap.shift.isOpen,
              let shiftOperator = bootstrap.shift.activeOperator else {
            return bootstrap?.shift.isOpen == true
        }

        return shiftOperator.id == bootstrap.operator.id
    }

    var activeDrawerOperatorName: String? {
        guard let bootstrap,
              let activeOperator = bootstrap.shift.activeOperator,
              activeOperator.id != bootstrap.operator.id else {
            return nil
        }

        return activeOperator.name
    }

    func setStaffSessionToken(_ token: String) {
        staffSessionToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearStaffSession() {
        staffSessionToken = ""
        recap = nil
        recapErrorMessage = nil
        saleMessage = nil
        errorMessage = nil
        isShiftSubmitting = false
        isSubmitting = false
    }

    func loadCachedBootstrapIfAvailable() {
        guard bootstrap == nil, let cached = POSBootstrapCache.load() else { return }
        bootstrap = cached
        isConnected = false
    }

    func applyLocalOperator(_ posOperator: POSOperator) {
        if let current = bootstrap {
            bootstrap = POSBootstrapResponse(operator: posOperator, catalog: current.catalog, shift: current.shift)
        } else {
            bootstrap = POSBootstrapResponse(operator: posOperator, catalog: .empty, shift: .offline)
        }
    }

    func preparePINOnlyLocalShiftState() {
        loadCachedBootstrapIfAvailable()

        guard !(POSLocalShiftStateStore.isOpen && POSLocalShiftStateStore.isOpenedFromAuth) else { return }

        POSLocalShiftStateStore.markClosed()

        guard let current = bootstrap else { return }
        let nextBootstrap = POSBootstrapResponse(
            operator: current.operator,
            catalog: current.catalog,
            shift: .offline
        )
        bootstrap = nextBootstrap
        POSBootstrapCache.save(nextBootstrap)
    }

    func authenticateStaffPIN(baseURL: String, token: String, pin: String, openingCash: Double?, showsProgress: Bool = true) async -> POSPinSessionResponse? {
        guard !isPinAuthenticating else { return nil }

        let trimmedPIN = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...6).contains(trimmedPIN.count) else {
            pinErrorMessage = "Enter a 4-6 digit PIN."
            Haptics.notification(.error)
            return nil
        }

        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pinErrorMessage = "Add the emberOS Key in Settings first."
            Haptics.notification(.error)
            return nil
        }

        if showsProgress {
            isPinAuthenticating = true
        }
        pinErrorMessage = nil
        errorMessage = nil

        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token).openPOSPinSession(
                POSPinSessionRequest(
                    pin: trimmedPIN,
                    openingCash: openingCash,
                    deviceName: UIDevice.current.name
                )
            )
            staffSessionToken = response.sessionToken
            pinErrorMessage = nil
            bootstrap = bootstrap.map {
                POSBootstrapResponse(operator: response.operator, catalog: $0.catalog, shift: $0.shift)
            }
            isConnected = true
            if showsProgress {
                isPinAuthenticating = false
                Haptics.notification(.success)
            }
            return response
        } catch {
            if showsProgress {
                pinErrorMessage = error.localizedDescription
            }
            isConnected = false
            if showsProgress {
                isPinAuthenticating = false
                Haptics.notification(.error)
            }
            return nil
        }
    }

    func quantityInCart(for product: POSProduct) -> Int {
        productQuantities[product.id] ?? 0
    }

    func imageURL(for product: POSProduct) -> URL? {
        if let override = productImageOverrideURLs[product.id] {
            return override
        }

        guard let remote = product.imageURL else { return nil }
        return POSProductImageCache.shared.cachedFileURL(for: remote) ?? remote
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

    func setBrandLogoOverride(data: Data) async {
        guard let image = UIImage(data: data),
              let logoData = image.normalizedForPOSLogo().pngData(),
              let directory = productImageOverridesDirectory(createIfNeeded: true) else {
            errorMessage = "This logo could not be saved."
            Haptics.notification(.error)
            return
        }

        let fileURL = directory.appendingPathComponent(brandLogoFileName)

        do {
            try logoData.write(to: fileURL, options: [.atomic])
            brandLogoOverrideURL = fileURL
            errorMessage = nil
            Haptics.notification(.success)
        } catch {
            errorMessage = "This logo could not be saved."
            Haptics.notification(.error)
        }
    }

    func clearBrandLogoOverride() {
        guard let fileURL = brandLogoOverrideURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        brandLogoOverrideURL = nil
        Haptics.impact(.light)
    }

    func add(product: POSProduct, toppings: [POSTopping]) {
        invalidateRewardQuote()
        let lineID = POSCartLine.makeID(product: product, toppings: toppings)

        if let index = cartLines.firstIndex(where: { $0.id == lineID }) {
            cartLines[index].quantity += 1
        } else {
            cartLines.append(POSCartLine(product: product, toppings: toppings, quantity: 1))
        }

        syncActiveTicket()
        Haptics.impact(.light)
    }

    func increment(line: POSCartLine) {
        guard let index = cartLines.firstIndex(where: { $0.id == line.id }) else { return }
        invalidateRewardQuote()
        cartLines[index].quantity += 1
        syncActiveTicket()
        Haptics.impact(.light)
    }

    func decrement(line: POSCartLine) {
        guard let index = cartLines.firstIndex(where: { $0.id == line.id }) else { return }
        invalidateRewardQuote()

        if cartLines[index].quantity <= 1 {
            cartLines.remove(at: index)
        } else {
            cartLines[index].quantity -= 1
        }

        syncActiveTicket()
        Haptics.impact(.light)
    }

    func remove(line: POSCartLine) {
        invalidateRewardQuote()
        cartLines.removeAll { $0.id == line.id }
        syncActiveTicket()
        Haptics.impact(.medium)
    }

    func setMarketplaceUnitPrice(line: POSCartLine, price: Double?) {
        guard let index = cartLines.firstIndex(where: { $0.id == line.id }) else { return }
        invalidateRewardQuote()
        var updatedLines = cartLines
        updatedLines[index].adjustedUnitPrice = price.map { max(0, $0) }
        cartLines = updatedLines
        syncActiveTicket()
    }

    func updateToppings(line: POSCartLine, toppings: [POSTopping]) {
        guard let currentIndex = cartLines.firstIndex(where: { $0.id == line.id }) else { return }
        invalidateRewardQuote()

        let updatedLine = POSCartLine(
            product: cartLines[currentIndex].product,
            toppings: toppings,
            quantity: cartLines[currentIndex].quantity,
            adjustedUnitPrice: cartLines[currentIndex].adjustedUnitPrice
        )

        var updatedLines = cartLines

        if let existingIndex = updatedLines.firstIndex(where: { $0.id == updatedLine.id }),
           existingIndex != currentIndex {
            updatedLines[existingIndex].quantity += updatedLine.quantity
            if updatedLines[existingIndex].adjustedUnitPrice == nil {
                updatedLines[existingIndex].adjustedUnitPrice = updatedLine.adjustedUnitPrice
            }
            updatedLines.remove(at: currentIndex)
        } else {
            updatedLines[currentIndex] = updatedLine
        }

        cartLines = updatedLines
        syncActiveTicket()
        Haptics.impact(.light)
    }

    func clearCart() {
        invalidateRewardQuote(clearRedemption: true)
        cartLines.removeAll()
        syncActiveTicket()
        Haptics.notification(.success)
    }

    func createNewTicket() {
        invalidateRewardQuote(clearRedemption: true)
        syncActiveTicket()

        if cartLines.isEmpty, tickets.contains(where: { $0.id == activeTicketID && $0.lines.isEmpty }) {
            Haptics.impact(.light)
            return
        }

        nextTicketNumber += 1
        let ticket = POSDraftTicket(number: nextTicketNumber)
        tickets.append(ticket)
        activeTicketID = ticket.id
        cartLines = []
        rebuildProductQuantities()
        persistDraftTickets()
        Haptics.notification(.success)
    }

    func switchTicket(_ ticket: POSDraftTicket) {
        guard ticket.id != activeTicketID else { return }
        invalidateRewardQuote(clearRedemption: true)

        syncActiveTicket()
        activeTicketID = ticket.id
        cartLines = ticket.lines
        rebuildProductQuantities()
        persistDraftTickets()
        Haptics.selectionChanged()
    }

    fileprivate func submitSale(
        baseURL: String,
        token: String,
        paymentMethod: POSPaymentMethod,
        orderSource: POSOrderSource,
        externalReference: String,
        customer: POSCustomer?,
        discountPercent: Double,
        notes: String,
        completionTotal: Double,
        shouldPrintReceipt: Bool,
        rewardRedemptionSessionID: String? = nil,
        rewardLineKey: String? = nil,
        onSyncedSale: (@MainActor (POSCreateSaleResponse, POSQueuedSale) async -> Void)? = nil
    ) async -> POSCreateSaleResponse? {
        guard !cartLines.isEmpty else {
            errorMessage = "Add at least one product before checkout."
            return nil
        }

        guard hasOpenShiftForCurrentOperator else {
            if let activeDrawerOperatorName {
                errorMessage = "\(activeDrawerOperatorName) is currently serving. Close that shift before opening POS."
            } else {
                errorMessage = "Open a shift and declare the cash drawer before completing sales."
            }
            Haptics.notification(.error)
            return nil
        }

        let cleanedExternalReference = externalReference.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        guard !orderSource.isMarketplace || cleanedExternalReference != nil else {
            errorMessage = "Enter the \(orderSource.label) reference before completing."
            Haptics.notification(.error)
            return nil
        }

        isSubmitting = true
        errorMessage = nil
        clearSaleMessage()

        let request = POSCreateSaleRequest(
            cart: cartLines.map(POSSaleCartItem.init(line:)),
            paymentMethod: paymentMethod.rawValue,
            orderSource: orderSource.rawValue,
            externalOrderReference: cleanedExternalReference,
            customerID: customer?.id ?? (rewardRedemptionSessionID == nil ? nil : activeRewardRedemption?.customerID),
            discountPercent: max(0, min(discountPercent, 100)),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            rewardRedemptionSessionID: rewardRedemptionSessionID,
            rewardQuoteID: rewardRedemptionSessionID == nil ? nil : activeRewardQuote?.id,
            rewardLineKey: rewardRedemptionSessionID == nil ? nil : rewardLineKey,
            checkoutToken: rewardRedemptionSessionID == nil ? "native-pos-\(UUID().uuidString)" : currentRewardCheckoutToken()
        )

        if rewardRedemptionSessionID != nil {
            do {
                let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken).submitPOSSale(request)
                let serverTotal = response.total ?? completionTotal
                removeActiveTicketAfterSale()
                applyLocalSaleToShift(paymentMethod: paymentMethod, total: serverTotal)
                activeRewardRedemption = nil
                activeRewardQuote = nil
                rewardCheckoutToken = nil
                isConnected = true
                showSaleMessage(response.message)
                Haptics.notification(.success)
                isSubmitting = false
                Task { await refreshRecap(baseURL: baseURL, token: token) }
                return response
            } catch {
                isConnected = false
                errorMessage = error.localizedDescription
                Haptics.notification(.error)
                isSubmitting = false
                return nil
            }
        }

        removeActiveTicketAfterSale()
        applyLocalSaleToShift(paymentMethod: paymentMethod, total: completionTotal)
        enqueueSaleSync(
            request,
            completionTotal: completionTotal,
            shouldPrintReceipt: shouldPrintReceipt,
            baseURL: baseURL,
            token: token,
            onSyncedSale: onSyncedSale
        )
        showSaleMessage("Sale saved. Syncing...")
        Haptics.notification(.success)
        isSubmitting = false
        return POSCreateSaleResponse(message: "Sale saved. Syncing...", saleID: -Int(Date().timeIntervalSince1970), alreadyProcessed: false, total: completionTotal, discount: nil)
    }

    fileprivate func scanRewardToken(baseURL: String, token: String, rawToken: String) async throws {
        clearSaleMessage()
        let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken)
            .scanRewardToken(POSRewardScanRequest(token: rawToken))
        rewardQuoteRevision = UUID()
        activeRewardRedemption = POSRewardRedemption(response: response)
        activeRewardQuote = nil
        rewardCheckoutToken = "native-pos-reward-\(UUID().uuidString)"
        isConnected = true
        showSaleMessage("Free Reward reserved for this checkout.")
    }

    fileprivate func quoteRewardSale(
        baseURL: String,
        token: String,
        paymentMethod: POSPaymentMethod,
        orderSource: POSOrderSource,
        externalReference: String,
        customer: POSCustomer?,
        discountPercent: Double,
        notes: String,
        rewardLineKey: String?
    ) async throws -> POSRewardQuote {
        guard let activeRewardRedemption else {
            throw KitchenAPIError.serverMessage(422, "/api/pos/reward-redemptions/quote", "Scan a reward QR before previewing.")
        }

        let mappedOrderSource = orderSource.rawValue
        let request = POSRewardQuoteRequest(
            cart: cartLines.map(POSSaleCartItem.init(line:)),
            paymentMethod: paymentMethod.rawValue,
            orderSource: mappedOrderSource,
            externalOrderReference: externalReference.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            customerID: customer?.id ?? activeRewardRedemption.customerID,
            discountPercent: max(0, min(discountPercent, 100)),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            rewardRedemptionSessionID: activeRewardRedemption.sessionID,
            rewardLineKey: rewardLineKey,
            checkoutToken: currentRewardCheckoutToken()
        )

        let revision = UUID()
        rewardQuoteRevision = revision
        let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken)
            .quoteRewardSale(request)
        guard !Task.isCancelled, rewardQuoteRevision == revision,
              self.activeRewardRedemption?.sessionID == request.rewardRedemptionSessionID else {
            throw CancellationError()
        }
        activeRewardQuote = response.rewardQuote
        isConnected = true
        showSaleMessage("Reward total previewed by Laravel.")

        return response.rewardQuote
    }

    fileprivate func clearRewardRedemption() {
        invalidateRewardQuote(clearRedemption: true)
        Haptics.selectionChanged()
    }

    fileprivate func clearRewardQuote() {
        invalidateRewardQuote()
    }

    private func invalidateRewardQuote(clearRedemption: Bool = false) {
        rewardQuoteRevision = UUID()
        activeRewardQuote = nil

        if clearRedemption {
            activeRewardRedemption = nil
            rewardCheckoutToken = nil
        }
    }

    private func currentRewardCheckoutToken() -> String {
        if let rewardCheckoutToken {
            return rewardCheckoutToken
        }

        let token = "native-pos-reward-\(UUID().uuidString)"
        rewardCheckoutToken = token
        return token
    }

    private func applyLocalSaleToShift(paymentMethod: POSPaymentMethod, total: Double) {
        guard let currentShiftEnvelope = bootstrap?.shift,
              currentShiftEnvelope.isOpen,
              let currentShift = currentShiftEnvelope.shift else {
            return
        }

        let currentRecap = currentShiftEnvelope.recap
        let nextOrders = (currentRecap?.orders ?? 0) + 1
        let nextRevenue = (currentRecap?.revenue ?? 0) + total
        let cashDelta = paymentMethod == .cash ? total : 0
        let nextRecap = POSShiftRecap(
            orders: nextOrders,
            revenue: nextRevenue,
            averageTicket: nextOrders > 0 ? nextRevenue / Double(nextOrders) : 0,
            expectedCash: (currentRecap?.expectedCash ?? currentShift.openingCash) + cashDelta,
            cashSales: (currentRecap?.cashSales ?? 0) + cashDelta,
            cashDeposited: currentRecap?.cashDeposited ?? 0,
            cashWithdrawn: currentRecap?.cashWithdrawn ?? 0
        )

        applyLocalShift(POSShiftEnvelope(isOpen: true, shift: currentShift, recap: nextRecap))
    }

    private func enqueueSaleSync(
        _ request: POSCreateSaleRequest,
        completionTotal: Double,
        shouldPrintReceipt: Bool,
        baseURL: String,
        token: String,
        onSyncedSale: (@MainActor (POSCreateSaleResponse, POSQueuedSale) async -> Void)?
    ) {
        var queue = POSQueuedSaleStore.load()
        queue.append(POSQueuedSale(request: request, createdAt: Date(), completionTotal: completionTotal, shouldPrintReceipt: shouldPrintReceipt))
        POSQueuedSaleStore.save(queue)
        pendingSaleSyncCount = queue.count
        syncQueuedSales(baseURL: baseURL, token: token, onSyncedSale: onSyncedSale)
    }

    fileprivate func syncQueuedSales(
        baseURL: String,
        token: String,
        onSyncedSale: (@MainActor (POSCreateSaleResponse, POSQueuedSale) async -> Void)? = nil
    ) {
        guard saleSyncTask == nil else { return }

        saleSyncTask = Task { [weak self] in
            guard let self else { return }
            var queue = POSQueuedSaleStore.load()
            var syncedAny = false

            while let sale = queue.first {
                do {
                    let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: self.staffSessionToken).submitPOSSale(sale.request)
                    queue.removeFirst()
                    POSQueuedSaleStore.save(queue)
                    syncedAny = true
                    if let onSyncedSale {
                        await onSyncedSale(response, sale)
                    }
                    await MainActor.run {
                        self.pendingSaleSyncCount = queue.count
                        self.isConnected = true
                        self.showSaleMessage(response.message)
                    }
                } catch {
                    if error.isValidationFailure {
                        let reviewReason = error.posReviewReason
                        let reviewMessage = self.queuedSaleReviewMessage(for: sale, reason: reviewReason)
                        queue.removeFirst()
                        POSQueuedSaleStore.save(queue)
                        POSFailedQueuedSaleStore.append(sale, reason: reviewReason)
                        await MainActor.run {
                            self.pendingSaleSyncCount = queue.count
                            self.isConnected = true
                            self.errorMessage = reviewMessage
                            Task { await self.refresh(baseURL: baseURL, token: token) }
                        }
                        continue
                    }

                    await MainActor.run {
                        self.pendingSaleSyncCount = queue.count
                        self.isConnected = false
                        self.errorMessage = "Sale sync pending. \(error.localizedDescription)"
                    }
                    break
                }
            }

            await MainActor.run {
                if syncedAny {
                    Task { await self.refreshRecap(baseURL: baseURL, token: token) }
                }
                self.saleSyncTask = nil
            }
        }
    }

    private func queuedSaleReviewMessage(for sale: POSQueuedSale, reason: String) -> String {
        let source = POSOrderSource(rawValue: sale.request.orderSource)?.label ?? "Sale"
        let reference = sale.request.externalOrderReference?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank

        if let reference {
            return "\(source) \(reference) needs review: \(reason)"
        }

        return "\(source) sale needs review: \(reason)"
    }

    private func syncActiveTicket() {
        guard let index = tickets.firstIndex(where: { $0.id == activeTicketID }) else {
            let ticket = POSDraftTicket(number: nextTicketNumber, lines: cartLines)
            tickets.append(ticket)
            activeTicketID = ticket.id
            rebuildProductQuantities()
            persistDraftTickets()
            return
        }

        tickets[index].lines = cartLines
        rebuildProductQuantities()
        persistDraftTickets()
    }

    private func removeActiveTicketAfterSale() {
        tickets.removeAll { $0.id == activeTicketID }

        if let nextTicket = tickets.first(where: { !$0.lines.isEmpty }) ?? tickets.first {
            activeTicketID = nextTicket.id
            cartLines = nextTicket.lines
            rebuildProductQuantities()
            persistDraftTickets()
            return
        }

        nextTicketNumber += 1
        let ticket = POSDraftTicket(number: nextTicketNumber)
        tickets = [ticket]
        activeTicketID = ticket.id
        cartLines = []
        rebuildProductQuantities()
        persistDraftTickets()
    }

    private func rebuildProductQuantities() {
        productQuantities = cartLines.reduce(into: [:]) { totals, line in
            totals[line.product.id, default: 0] += line.quantity
        }
    }

    private func persistDraftTickets() {
        POSDraftTicketStore.save(
            tickets: tickets,
            activeTicketID: activeTicketID,
            nextTicketNumber: nextTicketNumber
        )
    }

    func startShift(baseURL: String, token: String, openingCash: Double, notes: String) async -> Bool {
        guard !isShiftSubmitting else { return false }
        if let activeDrawerOperatorName {
            errorMessage = "\(activeDrawerOperatorName) is currently serving. Close that shift before opening a new one."
            Haptics.notification(.error)
            return false
        }

        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

        isShiftSubmitting = true
        errorMessage = nil
        clearSaleMessage()

        let request = POSStartShiftRequest(openingCash: openingCash, notes: cleanedNotes)
        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken).startPOSShift(request)
            POSLocalShiftStateStore.markOpen()
            applyLocalShift(response.shift)
            showSaleMessage("Shift opened.")
            isConnected = true
            isShiftSubmitting = false
            Haptics.notification(.success)
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
            isShiftSubmitting = false
            Haptics.notification(.error)
            return false
        }

        return true
    }

    func recordCashMovement(baseURL: String, token: String, type: POSCashMovementType, amount: Double, reason: String) async -> Bool {
        guard !isShiftSubmitting else { return false }
        guard let currentShift = bootstrap?.shift.shift else {
            errorMessage = "Open a shift before moving cash."
            Haptics.notification(.error)
            return false
        }

        let currentRecap = bootstrap?.shift.recap
        let isDeposit = type == .deposit
        let signedAmount = isDeposit ? amount : -amount
        let localRecap = POSShiftRecap(
            orders: currentRecap?.orders ?? 0,
            revenue: currentRecap?.revenue ?? 0,
            averageTicket: currentRecap?.averageTicket ?? 0,
            expectedCash: (currentRecap?.expectedCash ?? currentShift.openingCash) + signedAmount,
            cashSales: currentRecap?.cashSales ?? 0,
            cashDeposited: (currentRecap?.cashDeposited ?? 0) + (isDeposit ? amount : 0),
            cashWithdrawn: (currentRecap?.cashWithdrawn ?? 0) + (isDeposit ? 0 : amount)
        )

        isShiftSubmitting = true
        errorMessage = nil
        clearSaleMessage()
        applyLocalShift(POSShiftEnvelope(isOpen: true, shift: currentShift, recap: localRecap))
        showSaleMessage("Cash updated. Syncing...")
        Haptics.notification(.success)
        isShiftSubmitting = false

        let request = POSCashMovementRequest(
            type: type.rawValue,
            amount: amount,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        enqueueShiftMutation(.cashMovement(request), baseURL: baseURL, token: token)

        return true
    }

    func prepareShiftClosing(baseURL: String, token: String) async -> POSShiftEnvelope? {
        // Let in-flight updates finish before reading the authoritative drawer total.
        await refreshTask?.value
        await shiftSyncTask?.value
        await saleSyncTask?.value

        guard POSQueuedSaleStore.load().isEmpty, POSQueuedShiftMutationStore.load().isEmpty else {
            errorMessage = "Sales or cash movements are still waiting to sync. Connect and retry before closing the shift."
            return nil
        }

        errorMessage = nil
        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken).fetchPOSShift()
            guard response.shift.isOpen, response.shift.shift != nil, response.shift.recap != nil else {
                errorMessage = "No active shift totals are available. Refresh your shift and try again."
                return nil
            }
            applyLocalShift(response.shift)
            isConnected = true
            return response.shift
        } catch {
            errorMessage = "Could not load current drawer totals. \(error.localizedDescription)"
            isConnected = false
            return nil
        }
    }

    func endShift(baseURL: String, token: String, closingCash: Double?, notes: String) async -> Bool {
        guard !isShiftSubmitting else { return false }
        guard POSQueuedSaleStore.load().isEmpty, POSQueuedShiftMutationStore.load().isEmpty else {
            errorMessage = "Sales or cash movements are still waiting to sync. Retry after syncing before closing the shift."
            return false
        }
        guard bootstrap?.shift.shift != nil else {
            errorMessage = "No open shift to close."
            Haptics.notification(.error)
            return false
        }

        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        isShiftSubmitting = true
        errorMessage = nil
        clearSaleMessage()

        let request = POSEndShiftRequest(closingCash: closingCash, notes: cleanedNotes)
        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken).endPOSShift(request)
            POSLocalShiftStateStore.markClosed()
            applyLocalShift(response.shift)
            showSaleMessage("Shift closed.")
            isConnected = true
            isShiftSubmitting = false
            Haptics.notification(.success)
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
            isShiftSubmitting = false
            Haptics.notification(.error)
            return false
        }

        return true
    }

    private func applyLocalShift(_ shift: POSShiftEnvelope) {
        guard let currentBootstrap = bootstrap else { return }

        let nextBootstrap = POSBootstrapResponse(
            operator: currentBootstrap.operator,
            catalog: currentBootstrap.catalog,
            shift: shift
        )
        bootstrap = nextBootstrap
        POSBootstrapCache.save(nextBootstrap)
    }

    private func enqueueShiftMutation(_ mutation: POSQueuedShiftMutation, baseURL: String, token: String) {
        var queue = POSQueuedShiftMutationStore.load()
        queue.append(mutation)
        POSQueuedShiftMutationStore.save(queue)
        pendingShiftSyncCount = queue.count
        syncQueuedShiftMutations(baseURL: baseURL, token: token)
    }

    func syncQueuedShiftMutations(baseURL: String, token: String) {
        guard shiftSyncTask == nil else { return }

        shiftSyncTask = Task { [weak self] in
            guard let self else { return }
            var queue = POSQueuedShiftMutationStore.load()

            while let mutation = queue.first {
                do {
                    let response = try await self.performShiftMutation(mutation, baseURL: baseURL, token: token)
                    queue.removeFirst()
                    POSQueuedShiftMutationStore.save(queue)

                    await MainActor.run {
                        self.pendingShiftSyncCount = queue.count
                        self.applyLocalShift(response.shift)
                        self.isConnected = true
                    }
                } catch {
                    await MainActor.run {
                        self.pendingShiftSyncCount = queue.count
                        self.errorMessage = "Shift sync pending. \(error.localizedDescription)"
                        self.isConnected = false
                    }
                    break
                }
            }

            await MainActor.run {
                self.shiftSyncTask = nil
            }
        }
    }

    private func performShiftMutation(_ mutation: POSQueuedShiftMutation, baseURL: String, token: String) async throws -> POSShiftResponse {
        let client = KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken)

        switch mutation.kind {
        case .start:
            guard let request = mutation.startRequest else { throw KitchenAPIError.invalidResponse }
            return try await client.startPOSShift(request)
        case .cashMovement:
            guard let request = mutation.cashMovementRequest else { throw KitchenAPIError.invalidResponse }
            return try await client.recordPOSCashMovement(request)
        case .end:
            guard let request = mutation.endRequest else { throw KitchenAPIError.invalidResponse }
            return try await client.endPOSShift(request)
        }
    }

    private func showSaleMessage(_ message: String) {
        saleMessageClearTask?.cancel()
        saleMessage = message
        let expectedMessage = message

        saleMessageClearTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await MainActor.run {
                guard saleMessage == expectedMessage else { return }
                saleMessage = nil
                saleMessageClearTask = nil
            }
        }
    }

    private func clearSaleMessage() {
        saleMessageClearTask?.cancel()
        saleMessageClearTask = nil
        saleMessage = nil
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
            let serverBootstrap = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken).fetchPOSBootstrap()
            let localShift = bootstrap?.shift
            let nextBootstrap: POSBootstrapResponse

            if POSLocalShiftStateStore.hasLocalDecision, let localShift {
                let resolvedShift = localShift.isOpen
                    ? serverBootstrap.shift
                    : POSShiftEnvelope(
                        isOpen: false,
                        shift: nil,
                        recap: nil,
                        activeOperator: serverBootstrap.shift.activeOperator
                    )
                nextBootstrap = POSBootstrapResponse(
                    operator: serverBootstrap.operator,
                    catalog: serverBootstrap.catalog,
                    shift: resolvedShift
                )
            } else {
                nextBootstrap = serverBootstrap
            }

            bootstrap = nextBootstrap
            POSBootstrapCache.save(nextBootstrap)
            errorMessage = nil
            isConnected = true
            preloadForSmoothness(baseURL: baseURL, token: token)
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }

        isInitialLoading = false
        isRefreshing = false
    }

    func preloadForSmoothness(baseURL: String, token: String) {
        guard preloadTask == nil else { return }

        let products = bootstrap?.catalog.products ?? []
        let imageURLs = products.compactMap { imageURL(for: $0) }

        preloadTask = Task { [weak self] in
            await POSProductImageCache.shared.prewarm(urls: imageURLs)

            await MainActor.run {
                guard let self else { return }
                self.preloadTask = nil
            }
        }

        if recap == nil, !isRecapLoading {
            Task { await refreshRecap(baseURL: baseURL, token: token) }
        }
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
            recap = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: staffSessionToken).fetchPOSRecap().recap
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

    private func loadBrandLogoOverride() {
        guard let directory = productImageOverridesDirectory(createIfNeeded: false) else {
            return
        }

        let fileURL = directory.appendingPathComponent(brandLogoFileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            brandLogoOverrideURL = fileURL
        }
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
    var posSessionToken: String = ""

    func fetchPOSBootstrap() async throws -> POSBootstrapResponse {
        try await request(path: "/api/pos/bootstrap", method: "GET", body: Optional<KitchenStatusRequest>.none)
    }

    func openPOSPinSession(_ session: POSPinSessionRequest) async throws -> POSPinSessionResponse {
        try await request(path: "/api/pos/sessions/pin", method: "POST", body: session)
    }

    func fetchPOSRecap() async throws -> POSRecapResponse {
        try await request(path: "/api/pos/recap", method: "GET", body: Optional<KitchenStatusRequest>.none)
    }

    func submitPOSSale(_ sale: POSCreateSaleRequest) async throws -> POSCreateSaleResponse {
        try await request(path: "/api/pos/sales", method: "POST", body: sale)
    }

    func scanRewardToken(_ scan: POSRewardScanRequest) async throws -> POSRewardScanResponse {
        try await request(path: "/api/pos/reward-redemptions/scan", method: "POST", body: scan)
    }

    func quoteRewardSale(_ quote: POSRewardQuoteRequest) async throws -> POSRewardQuoteResponse {
        try await request(path: "/api/pos/reward-redemptions/quote", method: "POST", body: quote)
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

    func fetchPOSShift() async throws -> POSShiftResponse {
        try await request(path: "/api/pos/shift", method: "GET", body: Optional<KitchenStatusRequest>.none)
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

    func acceptOnlineOrder(_ order: KitchenOnlineOrder) async throws -> KitchenOnlineOrderResponse {
        try await request(
            path: "/api/kitchen/online-orders/\(order.id)/accept",
            method: "POST",
            body: Optional<KitchenStatusRequest>.none
        )
    }

    func markOnlineOrderPaid(_ order: KitchenOnlineOrder) async throws -> KitchenOnlineOrderResponse {
        try await request(
            path: "/api/kitchen/online-orders/\(order.id)/mark-paid",
            method: "POST",
            body: Optional<KitchenStatusRequest>.none
        )
    }

    func sendOnlineOrderToKitchen(_ order: KitchenOnlineOrder) async throws -> KitchenSendOnlineOrderToKitchenResponse {
        try await request(
            path: "/api/kitchen/online-orders/\(order.id)/send-to-kitchen",
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
        let trimmedPOSSession = posSessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPOSSession.isEmpty {
            request.setValue(trimmedPOSSession, forHTTPHeaderField: "X-POS-Staff-Session")
        }

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

enum GlacialFont {
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

private struct LaunchSplashView: View {
    let wallpaperAssetName: String
    let accentColor: Color
    let onFinished: () -> Void

    @State private var logoOpacity = 0.0
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()

            POSProductAreaWallpaper(assetName: wallpaperAssetName)
                .opacity(0.46)
                .ignoresSafeArea()

            Rectangle()
                .fill(.white.opacity(0.62))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image("EmberOSLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 310, height: 96)
                    .opacity(logoOpacity)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppPalette.line.opacity(0.72))
                        .frame(width: 172, height: 3)

                    Capsule()
                        .fill(accentColor)
                        .frame(width: 172 * progress, height: 3)
                }
                .opacity(logoOpacity)
            }
            .padding(.horizontal, 32)
        }
        .allowsHitTesting(true)
        .onAppear {
            runAnimation()
        }
    }

    private func runAnimation() {
        withAnimation(.easeInOut(duration: 2.0)) {
            logoOpacity = 1
        }

        withAnimation(.easeInOut(duration: 1.55).delay(0.28)) {
            progress = 1
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            onFinished()
        }
    }
}

private struct HeaderView: View {
    let activeCount: Int
    let readyCount: Int
    let oldestMinutes: Int?
    let isConnected: Bool
    let section: AppSection
    let brandLogoURL: URL?
    let isBrandLogoHidden: Bool
    let brandLogoScale: Double
    let cartItemCount: Int
    let openTicketCount: Int
    let cartTotal: Double
    let pendingSyncCount: Int
    let posAccentColor: Color
    let isPOSArrangeMode: Bool
    let isCompact: Bool
    let studioPeriod: String
    let onHome: () -> Void
    let onFinishPOSArrange: () -> Void
    let onCart: () -> Void
    let onStudioPeriodSelect: (String) -> Void

    var body: some View {
        HStack(alignment: isCompact ? .top : .center, spacing: isCompact ? 10 : 18) {
            Button(action: onHome) {
                BrandLogoHeader(url: brandLogoURL, isHidden: isBrandLogoHidden, scale: brandLogoScale, isCompact: isCompact)
            }
            .buttonStyle(NoHighlightButtonStyle())
            .accessibilityLabel("Go to POS home")
            .layoutPriority(0)

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
                VStack(alignment: .leading, spacing: 7) {
                    if isPOSArrangeMode {
                        Button(action: onFinishPOSArrange) {
                            Text("DONE")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2.0)
                                .foregroundStyle(posAccentColor)
                                .frame(width: 84, height: 30)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(posAccentColor.opacity(0.46), lineWidth: 1)
                                )
                        }
                        .buttonStyle(NoHighlightButtonStyle())
                    }

                    POSHeaderCartSummary(
                        itemCount: cartItemCount,
                        ticketCount: openTicketCount,
                        total: cartTotal,
                        isConnected: isConnected,
                        pendingSyncCount: pendingSyncCount,
                        accentColor: posAccentColor,
                        isCompact: isCompact,
                        onCart: onCart
                    )
                }
                .padding(.top, isCompact ? 18 : 0)
                .layoutPriority(2)
            case .studio:
                VStack(alignment: .trailing, spacing: 7) {
                    Text("EMBEROS STUDIO")
                        .font(GlacialFont.caption(.bold))
                        .tracking(2.4)
                        .foregroundStyle(posAccentColor)

                    HStack(spacing: 8) {
                        StudioPeriodMenuButton(
                            selectedPeriod: studioPeriod,
                            accentColor: posAccentColor,
                            onSelect: onStudioPeriodSelect
                        )

                        Text("· \(activeCount) ORDERS")
                            .font(GlacialFont.caption2(.bold))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .padding(.top, isCompact ? 8 : 14)
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
        case .studio:
            return isConnected ? "Studio live" : "Studio offline"
        }
    }
}

private struct StudioPeriodMenuButton: View {
    let selectedPeriod: String
    let accentColor: Color
    let onSelect: (String) -> Void

    private let periods = [
        ("today", "TODAY"),
        ("this_week", "WEEK"),
        ("this_month", "MONTH"),
        ("this_year", "YEAR")
    ]

    private var label: String {
        periods.first(where: { $0.0 == selectedPeriod })?.1 ?? selectedPeriod.uppercased()
    }

    var body: some View {
        Menu {
            ForEach(periods, id: \.0) { value, title in
                Button {
                    onSelect(value)
                } label: {
                    Label(title, systemImage: selectedPeriod == value ? "checkmark" : "calendar")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(GlacialFont.caption2(.bold))
                    .tracking(1.5)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(accentColor, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct BrandLogoHeader: View {
    let url: URL?
    let isHidden: Bool
    let scale: Double
    let isCompact: Bool
    @State private var preparedLogo: UIImage?
    @State private var preparedLogoURL: URL?

    private var clampedScale: CGFloat {
        min(max(CGFloat(scale), 0.6), 1.8)
    }

    private var baseSize: CGSize {
        isCompact ? CGSize(width: 190, height: 84) : CGSize(width: 340, height: 112)
    }

    private var frameWidth: CGFloat {
        min(baseSize.width * clampedScale, isCompact ? 214 : 430)
    }

    private var frameHeight: CGFloat {
        min(baseSize.height * clampedScale, isCompact ? 112 : 150)
    }

    private var leadingInset: CGFloat {
        isCompact ? 18 : 24
    }

    var body: some View {
        HStack(spacing: 0) {
            if isHidden {
                Color.clear
            } else if let url, url.isFileURL, preparedLogoURL == url, let displayImage = preparedLogo {
                logoImage(Image(uiImage: displayImage), aspectRatio: displayImage.logoAspectRatio)
            } else {
                logoImage(Image("EmberOSLogo"), aspectRatio: 2.8)
            }

            Spacer(minLength: 0)
        }
        .frame(width: frameWidth, height: frameHeight, alignment: .leading)
        .padding(.leading, isHidden ? 0 : leadingInset)
        .contentShape(Rectangle())
        .accessibilityLabel(isHidden ? "Brand logo hidden" : "Brand logo")
        .task(id: url) {
            await prepareImportedLogo()
        }
    }

    private func logoImage(_ image: Image, aspectRatio: CGFloat) -> some View {
        let targetHeight = min((isCompact ? CGFloat(68) : CGFloat(86)) * clampedScale, frameHeight)
        let maxWidth = frameWidth
        let targetWidth = min(maxWidth, max(1, targetHeight * aspectRatio))

        return image
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: targetWidth, height: targetHeight, alignment: .leading)
    }

    @MainActor
    private func prepareImportedLogo() async {
        guard let url, url.isFileURL, !isHidden else {
            preparedLogo = nil
            preparedLogoURL = nil
            return
        }

        if preparedLogoURL == url, preparedLogo != nil {
            return
        }

        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            UIImage(contentsOfFile: url.path)
        }.value
        let displayImage = image.flatMap { $0.croppedToVisiblePixels() ?? $0 }

        preparedLogo = displayImage
        preparedLogoURL = displayImage == nil ? nil : url
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

private enum CompactShellTab: Hashable {
    case pos
    case kitchen
    case shift
    case recap
    case settings
}

private struct CompactShellTabBar: View {
    let selectedTab: CompactShellTab
    let waitingOrderCount: Int
    let cartItemCount: Int
    let accentColor: Color
    let canAccessAdminFeatures: Bool
    let canAccessShiftAuth: Bool
    let canAccessRecap: Bool
    let canAccessPOS: Bool
    let onSelect: (AppSection) -> Void
    let onShift: () -> Void
    let onRecap: () -> Void
    let onSettings: () -> Void
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 8) {
            CompactShellTabButton(
                title: AppSection.pos.label,
                systemImage: selectedTab == .pos ? "house.fill" : "house",
                badgeCount: cartItemCount,
                tab: .pos,
                selectedTab: selectedTab,
                accentColor: accentColor,
                isEnabled: canAccessPOS,
                namespace: selectionNamespace
            ) {
                onSelect(.pos)
            }

            CompactShellTabButton(
                title: AppSection.kitchen.label,
                systemImage: "fork.knife",
                badgeCount: waitingOrderCount,
                tab: .kitchen,
                selectedTab: selectedTab,
                accentColor: accentColor,
                isEnabled: true,
                namespace: selectionNamespace
            ) {
                onSelect(.kitchen)
            }

            if canAccessRecap {
                CompactShellTabButton(
                    title: "Recap",
                    systemImage: "chart.bar",
                    badgeCount: 0,
                    tab: .recap,
                    selectedTab: selectedTab,
                    accentColor: accentColor,
                    isEnabled: true,
                    namespace: selectionNamespace,
                    action: onRecap
                )
            }

            if canAccessShiftAuth {
                CompactShellTabButton(
                    title: "Auth",
                    systemImage: "person",
                    badgeCount: 0,
                    tab: .shift,
                    selectedTab: selectedTab,
                    accentColor: accentColor,
                    isEnabled: true,
                    namespace: selectionNamespace,
                    action: onShift
                )
            }

            if canAccessAdminFeatures {
                CompactShellTabButton(
                    title: "Settings",
                    systemImage: "gearshape.fill",
                    badgeCount: 0,
                    tab: .settings,
                    selectedTab: selectedTab,
                    accentColor: accentColor,
                    isEnabled: true,
                    namespace: selectionNamespace,
                    action: onSettings
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 354)
        .background(.ultraThinMaterial, in: Capsule())
        .background(.white.opacity(0.54), in: Capsule())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 24, y: 10)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }
}

private struct CompactShellTabButton: View {
    let title: String
    let systemImage: String
    let badgeCount: Int
    let tab: CompactShellTab
    let selectedTab: CompactShellTab
    let accentColor: Color
    var isEnabled = true
    let namespace: Namespace.ID
    let action: () -> Void

    private var isSelected: Bool {
        selectedTab == tab
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)) {
                action()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(.white.opacity(0.34))
                            .matchedGeometryEffect(id: "compact-tab-pill", in: namespace)
                            .overlay(
                                Capsule()
                                    .stroke(.white.opacity(0.34), lineWidth: 1)
                            )
                    }

                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: isSelected ? .bold : .semibold))
                        .symbolRenderingMode(.monochrome)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)

                if badgeCount > 0 {
                    Text("\(min(badgeCount, 9))")
                        .font(GlacialFont.caption2(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(accentColor, in: Circle())
                        .offset(x: -8, y: 2)
                }
            }
            .foregroundStyle(isEnabled ? (isSelected ? AppPalette.ink : AppPalette.ink.opacity(0.84)) : AppPalette.ink.opacity(0.28))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .animation(.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08), value: selectedTab)
        .animation(.snappy(duration: 0.18), value: badgeCount)
    }
}

private struct POSStaffPinGateView: View {
    @Binding var pin: String
    let isSubmitting: Bool
    let errorMessage: String?
    let accentColor: Color
    let needsEmberKey: Bool
    let onSubmit: (String) -> Void
    let onSetupKey: () -> Void
    let onSignInLater: () -> Void
    @State private var localErrorMessage: String?
    private let panelCornerRadius: CGFloat = 8

    private let keypadRows = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["delete.left", "0", "arrow.right"]
    ]

    private var displayErrorMessage: String? {
        localErrorMessage ?? errorMessage
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.white
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}

                VStack(spacing: 18) {
                    Image("EmberOSLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(proxy.size.width * 0.36, 210))
                        .opacity(0.94)

                    pinPanel
                }
                .frame(width: min(proxy.size.width - 36, 390))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .offset(y: -28)
            }
        }
    }

    private var pinPanel: some View {
        VStack(spacing: 22) {
            VStack(spacing: 7) {
                Text("STAFF PIN")
                    .font(GlacialFont.caption(.bold))
                    .tracking(3.4)
                    .foregroundStyle(AppPalette.muted)

                Text("Enter your 4-6 digit code")
                    .font(GlacialFont.subheadline())
                    .foregroundStyle(AppPalette.ink.opacity(0.78))
            }

            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? accentColor : AppPalette.ink.opacity(0.12))
                        .frame(width: index < pin.count ? 12 : 9, height: index < pin.count ? 12 : 9)
                }
            }
            .frame(height: 16)

            if let displayErrorMessage {
                Text(displayErrorMessage)
                    .font(GlacialFont.caption())
                    .foregroundStyle(Color(red: 0.68, green: 0.20, blue: 0.18))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            VStack(spacing: 10) {
                ForEach(keypadRows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row, id: \.self) { key in
                            pinKey(key)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .disabled(isSubmitting)
            .opacity(isSubmitting ? 0.62 : 1)

            if isSubmitting {
                ProgressView()
                    .tint(accentColor)
            }

            if needsEmberKey {
                Button(action: onSetupKey) {
                    POSRectActionLabel(
                        title: "SET EMBEROS KEY",
                        tint: accentColor,
                        isPrimary: true,
                        fillsWidth: true
                    )
                }
                .buttonStyle(.plain)
            }

            Button(action: onSignInLater) {
                Text("SIGN IN LATER")
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.ink.opacity(0.76))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
        .background(Color.white, in: RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .stroke(AppPalette.line.opacity(0.82), lineWidth: 1)
        )
    }

    private func pinKey(_ key: String) -> some View {
        Button {
            handleKey(key)
        } label: {
            ZStack {
                Circle()
                    .fill(key == "arrow.right" && pin.count >= 4 ? accentColor.opacity(0.12) : AppPalette.card)
                    .overlay(
                        Circle()
                            .stroke(key == "arrow.right" && pin.count >= 4 ? accentColor.opacity(0.46) : AppPalette.line.opacity(0.78), lineWidth: 1)
                    )

                if key == "delete.left" || key == "arrow.right" {
                    Image(systemName: key)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(key == "arrow.right" && pin.count >= 4 ? accentColor : AppPalette.ink.opacity(0.55))
                } else {
                    Text(key)
                        .font(.system(size: 25, weight: .regular, design: .rounded))
                        .foregroundStyle(AppPalette.ink)
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
    }

    private func handleKey(_ key: String) {
        switch key {
        case "delete.left":
            guard !pin.isEmpty else { return }
            pin.removeLast()
            Haptics.selectionChanged()
        case "arrow.right":
            submitIfReady()
        default:
            guard pin.count < 6 else { return }
            pin.append(key)
            Haptics.selectionChanged()
            if pin.count == 6 {
                submitIfReady()
            }
        }
    }

    private func submitIfReady() {
        guard pin.count >= 4 else {
            localErrorMessage = "Enter your PIN first."
            Haptics.impact(.light)
            return
        }

        localErrorMessage = nil
        onSubmit(pin)
    }
}

private struct POSOpeningCashDeclarationOverlay: View {
    @Binding var openingCashText: String
    let isSubmitting: Bool
    let errorMessage: String?
    let accentColor: Color
    let onConfirm: (Double) -> Void
    let onBack: () -> Void
    let onSignInLater: () -> Void
    @State private var isPanelPresented = false
    @State private var localErrorMessage: String?
    private let panelCornerRadius: CGFloat = 8

    private var declaredOpeningCash: Double? {
        let digits = openingCashText.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return Double(digits)
    }

    private var displayErrorMessage: String? {
        localErrorMessage ?? errorMessage
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.10))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            Color.black.opacity(0.03)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 18) {
                Spacer(minLength: 26)

                VStack(spacing: 22) {
                    Image(systemName: "banknote")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 54, height: 54)
                        .background(accentColor.opacity(0.10), in: Circle())

                    VStack(spacing: 7) {
                        Text("OPENING CASH")
                            .font(GlacialFont.caption(.bold))
                            .tracking(3.2)
                            .foregroundStyle(AppPalette.muted)

                        Text("Declare the cash in the register before opening the shift.")
                            .font(GlacialFont.subheadline())
                            .foregroundStyle(AppPalette.ink.opacity(0.78))
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("CASH IN REGISTER")
                            .font(GlacialFont.caption2(.bold))
                            .tracking(1.8)
                            .foregroundStyle(AppPalette.muted)

                        HStack(spacing: 10) {
                            TextField("Amount", text: $openingCashText)
                                .font(GlacialFont.headline(.semibold))
                                .keyboardType(.numberPad)
                                .foregroundStyle(AppPalette.ink)
                                .foregroundColor(AppPalette.ink)
                                .tint(accentColor)
                                .onChange(of: openingCashText) { _, value in
                                    let formatted = formattedCashInput(value)
                                    if formatted != value {
                                        openingCashText = formatted
                                    }
                                    localErrorMessage = nil
                                }

                            Text("VND")
                                .font(GlacialFont.caption(.bold))
                                .tracking(1.1)
                                .foregroundStyle(AppPalette.muted)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 13)
                        .lightGlassBackground(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(0.54), lineWidth: 1)
                        )
                    }

                    if let displayErrorMessage {
                        Text(displayErrorMessage)
                            .font(GlacialFont.caption())
                            .foregroundStyle(Color(red: 0.68, green: 0.20, blue: 0.18))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                            .transition(.opacity)
                    }

                    Button {
                        confirm()
                    } label: {
                        HStack(spacing: 9) {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            }

                            Text(isSubmitting ? "OPENING SHIFT" : "OPEN SHIFT")
                                .font(GlacialFont.caption(.bold))
                                .tracking(1.8)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.76 : 1)

                    Button("BACK TO PIN", action: onBack)
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.muted)
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 30)
                .frame(width: min(UIScreen.main.bounds.width - 44, 390))
                .lightGlassBackground(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
                .background(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            .white.opacity(0.24),
                            accentColor.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                )
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.54), .white.opacity(0.12), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.92), .white.opacity(0.34), .white.opacity(0.66)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: accentColor.opacity(0.10), radius: 22, y: 12)
                .shadow(color: .black.opacity(0.10), radius: 34, y: 18)

                Button(action: onSignInLater) {
                    Text("SIGN IN LATER")
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.ink.opacity(0.76))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .lightGlassBackground(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(0.58), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: min(UIScreen.main.bounds.width - 44, 390))
                .padding(.top, 8)
                .disabled(isSubmitting)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
            .opacity(isPanelPresented ? 1 : 0)
            .scaleEffect(isPanelPresented ? 1 : 0.965)
        }
        .animation(.easeInOut(duration: 0.22), value: errorMessage)
        .animation(.easeInOut(duration: 0.22), value: localErrorMessage)
        .onAppear {
            isPanelPresented = false
            withAnimation(.easeOut(duration: 0.18)) {
                isPanelPresented = true
            }
        }
    }

    private func confirm() {
        guard let declaredOpeningCash else {
            localErrorMessage = "Declare the cash in the register."
            Haptics.notification(.error)
            return
        }

        localErrorMessage = nil
        onConfirm(declaredOpeningCash)
    }

    private func formattedCashInput(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty, let number = Int(digits) else { return "" }
        return number.formatted()
    }
}

private struct AnimatedSuccessCheckmark: View {
    let accentColor: Color
    let size: CGFloat
    @State private var circleProgress: CGFloat = 0
    @State private var checkProgress: CGFloat = 0
    @State private var glowOpacity: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(0.10))
                .frame(width: size, height: size)
                .scaleEffect(glowOpacity > 0 ? 1.18 : 0.92)
                .opacity(glowOpacity)

            Circle()
                .stroke(accentColor.opacity(0.18), lineWidth: 6)
                .frame(width: size, height: size)

            Circle()
                .trim(from: 0, to: circleProgress)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)

            CheckmarkShape()
                .trim(from: 0, to: checkProgress)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.48, height: size * 0.36)
                .offset(y: -1)
        }
        .onAppear {
            circleProgress = 0
            checkProgress = 0
            glowOpacity = 0

            withAnimation(.easeOut(duration: 0.72)) {
                circleProgress = 1
                glowOpacity = 1
            }

            withAnimation(.easeOut(duration: 0.58).delay(0.54)) {
                checkProgress = 1
            }

            withAnimation(.easeInOut(duration: 1.25).delay(0.82)) {
                glowOpacity = 0.22
            }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct POSPinWelcomeOverlay: View {
    let welcome: POSPinWelcome
    let accentColor: Color
    @State private var isPresented = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                AnimatedSuccessCheckmark(accentColor: accentColor, size: 58)

                VStack(spacing: 7) {
                    Text("Welcome, \(welcome.operatorName).")
                        .font(GlacialFont.title3(.bold))
                        .foregroundStyle(AppPalette.ink)
                        .multilineTextAlignment(.center)

                    Text("Your shift starts now.")
                        .font(GlacialFont.subheadline())
                        .foregroundStyle(AppPalette.muted)

                    Text("Opening Cash : \(welcome.openingCash.currencyText)")
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.1)
                        .foregroundStyle(AppPalette.ink.opacity(0.76))
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
            .frame(width: min(UIScreen.main.bounds.width - 44, 380))
            .lightGlassBackground(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .background(.white.opacity(0.64), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(.white.opacity(0.78), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 30, y: 16)
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(isPresented ? 1 : 0.955)
            .offset(y: isPresented ? 0 : 10)
        }
        .onAppear {
            isPresented = false
            withAnimation(.easeOut(duration: 0.18)) {
                isPresented = true
            }
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

private enum PrintReceiptResult: Equatable {
    case printed
    case skipped
    case failed(String)

    var title: String {
        switch self {
        case .printed: "RECEIPT PRINTED"
        case .skipped: "NO RECEIPT"
        case .failed: "PRINT FAILED"
        }
    }

    var detail: String {
        switch self {
        case .printed: "Receipt sent to printer."
        case .skipped: "Sale saved without printing."
        case .failed(let message): message
        }
    }

    var icon: String {
        switch self {
        case .printed: "printer.fill"
        case .skipped: "printer"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var canAutoDismiss: Bool {
        switch self {
        case .printed, .skipped: true
        case .failed: false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct POSSaleCompletion: Identifiable, Equatable {
    let id = UUID()
    let saleID: Int
    let total: Double
    let printResult: PrintReceiptResult
}

private struct POSSaleCompletionOverlay: View {
    let completion: POSSaleCompletion
    let accentColor: Color
    let onRetry: () -> Void
    let onDismiss: () -> Void
    @State private var ringProgress: CGFloat = 0
    @State private var checkProgress: CGFloat = 0
    @State private var contentScale: CGFloat = 0.92

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(accentColor.opacity(0.09))
                    .frame(width: 74, height: 74)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 46, height: 46)

                POSCompletionCheckmark()
                    .trim(from: 0, to: checkProgress)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 28, height: 22)
            }

            VStack(spacing: 4) {
                Text("SALE COMPLETED")
                    .font(GlacialFont.subheadline(.semibold))
                    .tracking(2.4)
                    .foregroundStyle(AppPalette.ink)

                Text("#\(completion.saleID)  \(Int(completion.total).formatted()) VND")
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.4)
                    .foregroundStyle(AppPalette.muted)

                HStack(spacing: 7) {
                    Image(systemName: completion.printResult.icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(completion.printResult.title)
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.4)
                }
                .foregroundStyle(completion.printResult.isFailure ? AppPalette.red : accentColor)
                .padding(.top, 4)

                Text(completion.printResult.detail)
                    .font(GlacialFont.caption2())
                    .foregroundStyle(AppPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 260)
            }

            if completion.printResult.isFailure {
                HStack(spacing: 10) {
                    Button(action: onDismiss) {
                        POSRectActionLabel(title: "CLOSE", tint: AppPalette.ink)
                    }
                    .buttonStyle(.plain)

                    Button(action: onRetry) {
                        POSRectActionLabel(title: "RETRY PRINT", tint: accentColor, isPrimary: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
        .scaleEffect(contentScale)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                contentScale = 1
            }
            withAnimation(.easeOut(duration: 0.44)) {
                ringProgress = 1
            }
            withAnimation(.easeOut(duration: 0.34).delay(0.18)) {
                checkProgress = 1
            }
        }
    }
}

private struct POSCompletionCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.56))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.80))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.22))
        return path
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
    let ticketCount: Int
    let total: Double
    let isConnected: Bool
    let pendingSyncCount: Int
    let accentColor: Color
    let isCompact: Bool
    let onCart: () -> Void

    var body: some View {
        if isCompact {
            compactSummary
        } else {
            regularSummary
        }
    }

    private var compactSummary: some View {
        Button(action: onCart) {
            VStack(spacing: 3) {
                Image(systemName: "bag")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(accentColor)
                    .frame(width: 56, height: 42)

                ConnectionDot(isConnected: isConnected)
                    .scaleEffect(0.82)

                if pendingSyncCount > 0 {
                    Text("\(pendingSyncCount)")
                        .font(GlacialFont.caption2(.bold))
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: 76, height: 64)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(itemCount == 0 && ticketCount <= 1)
        .opacity(itemCount == 0 && ticketCount <= 1 ? 0.72 : 1)
        .accessibilityLabel("POS cart")
    }

    private var regularSummary: some View {
        Button(action: onCart) {
            HStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bag")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(accentColor)
                        .frame(width: 40, height: 36)

                    Text("\(itemCount)")
                        .font(GlacialFont.caption2(.bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(accentColor, in: Circle())
                        .offset(x: 4, y: -1)
                }
                .frame(width: 48, height: 42)

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(cartLabel)
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.7)
                        .foregroundStyle(AppPalette.ink)
                    Text("\(Int(total).formatted()) VND")
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(accentColor)
                    if pendingSyncCount > 0 {
                        Text("SYNC \(pendingSyncCount)")
                            .font(GlacialFont.caption2(.bold))
                            .tracking(1.1)
                            .foregroundStyle(accentColor)
                    } else {
                        ConnectionDot(isConnected: isConnected)
                    }
                }
            }
            .frame(width: 196, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(itemCount == 0 && ticketCount <= 1)
        .opacity(itemCount == 0 && ticketCount <= 1 ? 0.72 : 1)
        .accessibilityLabel("POS cart")
    }

    private var cartLabel: String {
        if ticketCount > 1 {
            return "\(ticketCount) TICKETS"
        }

        if itemCount == 0 {
            return "CART"
        }

        return itemCount == 1 ? "1 ITEM" : "\(itemCount) ITEMS"
    }
}

private struct POSCartBagIllustration: View {
    let itemCount: Int
    let accentColor: Color

    var body: some View {
        ZStack {
            Ellipse()
                .fill(accentColor.opacity(0.10))
                .frame(width: 40, height: 7)
                .offset(y: 22)

            POSCartBagShape()
                .fill(
                    LinearGradient(
                        colors: [.white, accentColor.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    POSCartBagShape()
                        .stroke(accentColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
                .shadow(color: accentColor.opacity(0.10), radius: 7, y: 4)

            POSCartBagPanel()
                .fill(accentColor.opacity(0.12))
                .frame(width: 24, height: 21)
                .offset(y: 8)

            POSCartBagStripe()
                .stroke(accentColor.opacity(0.42), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 25, height: 18)
                .offset(y: 6)

            POSCartBagHandle()
                .stroke(accentColor, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 16)
                .offset(y: -15)
        }
    }
}

private struct POSCartBagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let left = rect.minX + width * 0.16
        let right = rect.maxX - width * 0.16
        let top = rect.minY + height * 0.32
        let bottom = rect.maxY - height * 0.12
        let corner = width * 0.08

        path.move(to: CGPoint(x: left + corner, y: top))
        path.addLine(to: CGPoint(x: right - corner, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + corner), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - corner))
        path.addQuadCurve(to: CGPoint(x: right - corner, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + corner, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - corner), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top + corner))
        path.addQuadCurve(to: CGPoint(x: left + corner, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
}

private struct POSCartBagHandle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.42))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.42),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

private struct POSCartBagPanel: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.16, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct POSCartBagStripe: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.28))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.midY))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.22))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.22))
        return path
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
    let isCompact: Bool

    private var compactColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: 10),
            GridItem(.flexible(minimum: 0), spacing: 10)
        ]
    }

    var body: some View {
        Group {
            if isCompact {
                LazyVGrid(columns: compactColumns, spacing: 10) {
                    metrics
                }
            } else {
                HStack(spacing: 12) {
                    metrics
                }
            }
        }
    }

    @ViewBuilder
    private var metrics: some View {
        MetricCard(title: "Pending", value: "\(summary.pending)", icon: "bell.badge", tint: accentColor, isCompact: isCompact)
        MetricCard(title: "Preparing", value: "\(summary.preparing)", icon: "flame.fill", tint: AppPalette.red, isCompact: isCompact)
        MetricCard(title: "Ready", value: "\(summary.ready)", icon: "checkmark.seal.fill", tint: AppPalette.green, isCompact: isCompact)
        MetricCard(title: "Held", value: "\(summary.held)", icon: "pause.fill", tint: AppPalette.blue, isCompact: isCompact)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    let isCompact: Bool

    private var iconBoxSize: CGFloat {
        isCompact ? 48 : 56
    }

    var body: some View {
        HStack(spacing: isCompact ? 10 : 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.10))
                    .frame(width: iconBoxSize, height: iconBoxSize)
                Image(systemName: icon)
                    .font(.system(size: isCompact ? 25 : 30, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(GlacialFont.custom(isCompact ? 26 : 32, .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title)
                    .font(GlacialFont.caption2(.bold))
                    .foregroundStyle(AppPalette.muted)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: isCompact ? 64 : 76, maxHeight: isCompact ? 64 : nil)
        .padding(isCompact ? 8 : 10)
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
        VStack(alignment: .leading, spacing: 12) {
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

    static func columns(isCompact: Bool) -> [GridItem] {
        if isCompact {
            return [GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top)]
        }

        return threeColumns
    }
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
    let onSelect: (KitchenOnlineOrder) -> Void
    let onAccept: (KitchenOnlineOrder) -> Void
    let onMarkPaid: (KitchenOnlineOrder) -> Void
    let onSendToKitchen: (KitchenOnlineOrder) -> Void
    let onDecline: (KitchenOnlineOrder) -> Void
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Orders")
                    .font(GlacialFont.heading())
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                if !orders.isEmpty {
                    Text("\(orders.count) waiting")
                        .font(GlacialFont.footnote(.semibold))
                        .foregroundStyle(accentColor)
                }
            }

            if orders.isEmpty {
                Text("New orders will appear here when they need your attention.")
                    .font(GlacialFont.footnote(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: KitchenGrid.columns(isCompact: isCompact), spacing: 12) {
                    ForEach(orders, id: \.id) { order in
                        OnlineOrderCard(
                            order: order,
                            accentColor: accentColor,
                            onSelect: { onSelect(order) },
                            onAccept: { onAccept(order) },
                            onMarkPaid: { onMarkPaid(order) },
                            onSendToKitchen: { onSendToKitchen(order) },
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
    let onSelect: () -> Void
    let onAccept: () -> Void
    let onMarkPaid: () -> Void
    let onSendToKitchen: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 12) {
                    SourceArtwork(source: .website, status: .pending)
                        .frame(height: 108)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(order.orderNumber)
                                .font(GlacialFont.title3(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            Spacer(minLength: 6)
                            Text(order.elapsedText)
                                .font(GlacialFont.caption(.bold))
                                .foregroundStyle(accentColor)
                        }

                        HStack(spacing: 8) {
                            FulfillmentBadge(text: order.typeText, icon: order.fulfillmentIcon, tint: accentColor)
                            Text(order.cardContactText)
                                .font(GlacialFont.subheadline(.medium))
                                .foregroundStyle(AppPalette.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                    }

                    OnlineOrderItemPreview(items: order.items, accentColor: accentColor)

                    if let notes = order.notes, !notes.isEmpty {
                        Text(notes)
                            .font(GlacialFont.caption(.medium))
                            .foregroundStyle(AppPalette.muted)
                            .lineLimit(2)
                    }
                }
            }
            .buttonStyle(.plain)

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
                    Text(order.acceptedStateText)
                        .font(GlacialFont.caption2(.semibold))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    OnlineOrderCardActionButton(
                        systemImage: "trash",
                        tint: AppPalette.red,
                        accessibilityLabel: "Cancel order",
                        action: onDecline
                    )

                    if order.canMarkPaid {
                        OnlineOrderCardActionButton(
                            systemImage: "creditcard.fill",
                            tint: AppPalette.green,
                            accessibilityLabel: "Mark paid",
                            action: onMarkPaid
                        )
                    } else if order.canSendToKitchen {
                        OnlineOrderCardActionButton(
                            systemImage: "paperplane.fill",
                            tint: accentColor,
                            accessibilityLabel: "Send to kitchen",
                            action: onSendToKitchen
                        )
                    }
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

private struct OnlineOrderCardActionButton: View {
    let systemImage: String
    let tint: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(tint)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint.opacity(0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

private struct OnlineOrderItemPreview: View {
    let items: [KitchenOnlineOrderItem]
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.prefix(3), id: \.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(item.quantity)x")
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(accentColor)
                        .frame(width: 30, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.productName)
                            .font(GlacialFont.subheadline(.semibold))
                            .foregroundStyle(AppPalette.ink)
                        if !item.toppingText.isEmpty {
                            Text(item.toppingText)
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
    }
}

private struct FulfillmentBadge: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(GlacialFont.caption2(.bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct QueueSection: View {
    let orders: [KitchenOrder]
    let onlineDetailsBySaleID: [Int: KitchenOnlineOrder]
    let isInitialLoading: Bool
    let isRefreshing: Bool
    let accentColor: Color
    let onSelect: (KitchenOrder) -> Void
    let onStatus: (KitchenOrder, KitchenStatus) -> Void
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Queue")
                    .font(GlacialFont.heading())
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                if isRefreshing || isInitialLoading || !orders.isEmpty {
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
            }

            if orders.isEmpty && isInitialLoading {
                InitialLoadingView(accentColor: accentColor)
            } else if !orders.isEmpty {
                LazyVGrid(columns: KitchenGrid.columns(isCompact: isCompact), spacing: 12) {
                    ForEach(orders, id: \.id) { order in
                        OrderCard(
                            order: order,
                            onlineDetails: onlineDetailsBySaleID[order.id],
                            onSelect: { onSelect(order) },
                            onStatus: { onStatus(order, $0) }
                        )
                    }
                }
            }
        }
        .padding(.bottom, orders.isEmpty && !isInitialLoading ? 12 : 0)
    }
}

private struct CompletedKitchenSection: View {
    let tickets: [CompletedKitchenTicket]
    let accentColor: Color
    let onSelect: (CompletedKitchenTicket) -> Void
    let isCompact: Bool

    private var channels: [CompletedKitchenChannel] {
        CompletedKitchenChannel.allCases.map { channel in
            CompletedKitchenChannel(
                kind: channel.kind,
                tickets: tickets.filter { channel.contains($0) }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Completed")
                    .font(GlacialFont.heading())
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                if !tickets.isEmpty {
                    Text("\(tickets.count) saved")
                        .font(GlacialFont.footnote(.semibold))
                        .foregroundStyle(accentColor)
                }
            }

            if !tickets.isEmpty {
                LazyVGrid(columns: KitchenGrid.columns(isCompact: isCompact), spacing: 12) {
                    ForEach(channels) { channel in
                        CompletedKitchenChannelCard(
                            channel: channel,
                            accentColor: accentColor,
                            onSelect: onSelect
                        )
                    }
                }
            }
        }
    }
}

private struct CompletedKitchenChannel: Identifiable {
    let kind: CompletedKitchenChannelKind
    let tickets: [CompletedKitchenTicket]

    var id: String { kind.rawValue }

    static var allCases: [CompletedKitchenChannel] {
        CompletedKitchenChannelKind.allCases.map { CompletedKitchenChannel(kind: $0, tickets: []) }
    }

    func contains(_ ticket: CompletedKitchenTicket) -> Bool {
        kind.contains(ticket)
    }
}

private enum CompletedKitchenChannelKind: String, CaseIterable {
    case store
    case grab
    case shopee

    var title: String {
        switch self {
        case .store: "STORE"
        case .grab: "GRAB"
        case .shopee: "SHOPEE"
        }
    }

    var icon: String {
        switch self {
        case .store: "storefront"
        case .grab: "scooter"
        case .shopee: "bag"
        }
    }

    func contains(_ ticket: CompletedKitchenTicket) -> Bool {
        switch self {
        case .store:
            return ticket.source != "GRAB" && ticket.source != "SHOPEE"
        case .grab:
            return ticket.source == "GRAB"
        case .shopee:
            return ticket.source == "SHOPEE"
        }
    }
}

private struct CompletedKitchenChannelCard: View {
    let channel: CompletedKitchenChannel
    let accentColor: Color
    let onSelect: (CompletedKitchenTicket) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: channel.kind.icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accentColor)
                    .frame(width: 26, height: 26)
                    .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.kind.title)
                        .font(GlacialFont.caption(.bold))
                        .tracking(2)
                        .foregroundStyle(AppPalette.ink)

                    Text("\(channel.tickets.count) \(channel.tickets.count == 1 ? "receipt" : "receipts")")
                        .font(GlacialFont.caption2(.semibold))
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer(minLength: 0)
            }

            if channel.tickets.isEmpty {
                Text("No receipts yet")
                    .font(GlacialFont.caption(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(channel.tickets.prefix(7).enumerated()), id: \.element.id) { index, ticket in
                        CompletedKitchenReceiptRow(ticket: ticket, accentColor: accentColor) {
                            onSelect(ticket)
                        }
                        KitchenReceiptReprintButton(saleID: ticket.id)
                            .padding(.bottom, 8)

                        if index < min(channel.tickets.count, 7) - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 214, alignment: .topLeading)
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.green.opacity(0.24), lineWidth: 1)
        )
    }
}

private struct KitchenReceiptReprintButton: View {
    let saleID: Int
    @EnvironmentObject private var printStore: PrintBridgeStore
    @State private var isSending = false
    @State private var message: String?

    var body: some View {
        Button {
            isSending = true
            Task {
                let result = await printStore.reprintSaleReceipt(saleID: saleID)
                switch result {
                case .printed: message = "Receipt copy sent to the printer."
                case .failed(let reason): message = "Could not reprint receipt. \(reason)"
                case .skipped: message = "Receipt was not printed."
                }
                isSending = false
            }
        } label: {
            Label(isSending ? "Printing…" : "Reprint Receipt", systemImage: "printer")
                .font(GlacialFont.caption(.semibold))
        }
        .buttonStyle(.bordered)
        .disabled(isSending || printStore.isReprintingReceipt)
        .alert("Reprint Receipt", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

private struct CompletedKitchenReceiptRow: View {
    let ticket: CompletedKitchenTicket
    let accentColor: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ticket.orderNumber)
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.2)
                        .foregroundStyle(AppPalette.ink)

                    Text("\(ticket.completedTimeText) · \(ticket.paymentText)")
                        .font(GlacialFont.caption2(.medium))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(ticket.totalText)
                    .font(GlacialFont.caption(.bold))
                    .tracking(0.6)
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
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
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(18)
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

    var wallpaperAssetName: String {
        switch self {
        case .ember: "POSLightWallpaper"
        case .cocoa: "POSCocoaWallpaper"
        case .matcha: "POSMatchaWallpaper"
        case .midnight: "POSMidnightWallpaper"
        case .graphite: "POSGraphiteWallpaper"
        case .berry: "POSBerryWallpaper"
        }
    }
}

private enum POSCardSizeStorage {
    static func decode(_ raw: String) -> [Int: POSCardSize] {
        raw.split(separator: "|").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = Int(parts[0]), let size = POSCardSize(rawValue: parts[1]) else {
                return
            }
            result[id] = size
        }
    }

    static func encode(_ sizes: [Int: POSCardSize]) -> String {
        sizes
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { entry in "\(entry.key):\(entry.value.rawValue)" }
            .joined(separator: "|")
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

private struct POSSwipeCategoryPager<Content: View>: View {
    let pageCount: Int
    @Binding var currentIndex: Int
    let onSwipeActivity: () -> Void
    @ViewBuilder let content: (Int, CGFloat) -> Content

    private enum DragAxis {
        case horizontal
    }

    private let intentThreshold: CGFloat = 18
    private let directionBias: CGFloat = 1.25

    @State private var dragOffset: CGFloat = 0
    @State private var lockedDragAxis: DragAxis?
    @State private var didReportHorizontalDrag = false

    private var visiblePageIndices: [Int] {
        guard pageCount > 0 else { return [] }
        let lowerBound = max(0, currentIndex - 1)
        let upperBound = min(pageCount - 1, currentIndex + 1)
        return Array(lowerBound...upperBound)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack(alignment: .topLeading) {
                ForEach(visiblePageIndices, id: \.self) { index in
                    pageView(at: index, width: width, height: height)
                        .offset(x: CGFloat(index - currentIndex) * width)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .offset(x: dragOffset)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: intentThreshold)
                    .onChanged { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        let absHorizontal = abs(horizontal)
                        let absVertical = abs(vertical)

                        if lockedDragAxis == nil {
                            guard absHorizontal >= intentThreshold || absVertical >= intentThreshold else { return }

                            if absHorizontal > absVertical * directionBias {
                                lockedDragAxis = .horizontal
                            } else {
                                return
                            }
                        }

                        guard lockedDragAxis == .horizontal else { return }

                        var translation = horizontal
                        if (currentIndex == 0 && translation > 0) || (currentIndex == pageCount - 1 && translation < 0) {
                            translation *= 0.35
                        }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            dragOffset = translation
                        }
                        if !didReportHorizontalDrag {
                            didReportHorizontalDrag = true
                            onSwipeActivity()
                        }
                    }
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        let wasHorizontalDrag = lockedDragAxis == .horizontal
                        lockedDragAxis = nil

                        guard wasHorizontalDrag else {
                            didReportHorizontalDrag = false
                            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.08)) {
                                dragOffset = 0
                            }
                            return
                        }

                        let threshold = width * 0.28
                        let oldIndex = currentIndex
                        var next = currentIndex
                        if value.translation.width < -threshold || value.predictedEndTranslation.width < -width * 0.5 {
                            next = min(pageCount - 1, currentIndex + 1)
                        } else if value.translation.width > threshold || value.predictedEndTranslation.width > width * 0.5 {
                            next = max(0, currentIndex - 1)
                        }

                        let targetOffset: CGFloat
                        if next > oldIndex {
                            targetOffset = -width
                        } else if next < oldIndex {
                            targetOffset = width
                        } else {
                            targetOffset = 0
                        }

                        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.12)) {
                            dragOffset = targetOffset
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                currentIndex = next
                                dragOffset = 0
                            }
                        }

                        if next != oldIndex {
                            Haptics.selectionChanged()
                        }
                        if !didReportHorizontalDrag, abs(horizontal) > intentThreshold, abs(horizontal) > abs(vertical) * directionBias {
                            onSwipeActivity()
                        }
                        didReportHorizontalDrag = false
                    }
            , including: .gesture)
        }
        .clipped()
    }

    @ViewBuilder
    private func pageView(at index: Int, width: CGFloat, height: CGFloat) -> some View {
        let horizontalInset: CGFloat = 7
        let contentWidth = max(1, width - (horizontalInset * 2))

        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)

            if index >= 0, index < pageCount {
                content(index, contentWidth)
            }
        }
        .padding(.horizontal, horizontalInset)
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

private struct POSDashboardView: View {
    @ObservedObject var store: POSStore
    let baseURL: String
    let token: String
    let displayStyle: POSProductDisplayStyle
    let toppingCategoryOrder: [String]
    let accentColor: Color
    @Binding var isArrangeMode: Bool
    @Binding var isCheckoutOpen: Bool
    let categorySwipeCommand: POSCategorySwipeCommand
    let isCompact: Bool
    @State private var selectedCategory: String?
    @State private var selectedProduct: POSProduct?
    @State private var wobblePhase = false
    @State private var arrangedCategoryNames: [String] = []
    @State private var arrangedProductIDsByScope: [String: [Int]] = [:]
    @State private var draggingCategoryName: String?
    @State private var draggingProductID: Int?
    @State private var draggingProductOffset: CGSize = .zero
    @State private var lastCategoryDropTarget: String?
    @State private var lastProductDropTarget: Int?
    @State private var productAnimationToken = UUID()
    @State private var categorySlideDirection = 1
    @State private var suppressProductTapUntil = Date.distantPast
    @AppStorage("POSProductCardSizes") private var productCardSizesRaw = ""
    @State private var productGridWidth: CGFloat = 720
    @Namespace private var categorySelectionNamespace

    private let allProductsScope = "__all_products__"
    private var layoutProductGridWidth: CGFloat {
        isCompact ? min(productGridWidth, 430) : productGridWidth
    }

    private var compactPagerMinimumHeight: CGFloat {
        max(520, UIScreen.main.bounds.height - 360)
    }

    private var regularPagerMinimumHeight: CGFloat {
        560
    }

    private var productCardSizes: [Int: POSCardSize] {
        get { POSCardSizeStorage.decode(productCardSizesRaw) }
        nonmutating set { productCardSizesRaw = POSCardSizeStorage.encode(newValue) }
    }

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

        return products(for: selectedCategory)
    }

    private func products(for categoryName: String) -> [POSProduct] {
        let source = store.bootstrap?.catalog.products.filter { $0.category == categoryName } ?? []
        return orderedProducts(source, scope: categoryName)
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

    private func productTilePlacements(products: [POSProduct], width: CGFloat, spacing: CGFloat) -> (placements: [ProductTilePlacement], height: CGFloat) {
        let columns = 4
        let cell = max(72, (width - (spacing * CGFloat(columns - 1))) / CGFloat(columns))
        var placements: [ProductTilePlacement] = []
        var occupied: Set<String> = []

        for product in products {
            let cardSize = productCardSize(for: product)
            let columnSpan = min(max(1, columnSpan(for: cardSize)), columns)
            let rowSpan = max(1, rowSpan(for: cardSize))
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

    private func productTilePlacements(width: CGFloat, spacing: CGFloat) -> (placements: [ProductTilePlacement], height: CGFloat) {
        productTilePlacements(products: products, width: width, spacing: spacing)
    }

    private func productGridHeight(for categoryName: String) -> CGFloat {
        let spacing: CGFloat = 14
        switch displayStyle {
        case .productCard:
            return max(productTilePlacements(products: products(for: categoryName), width: layoutProductGridWidth, spacing: spacing).height, 1)
        case .grabGrid:
            let productCount = products(for: categoryName).count
            guard productCount > 0 else { return 1 }
            let width = max(1, layoutProductGridWidth)
            let columns = max(1, Int((width + 12) / (150 + 12)))
            let rows = Int(ceil(Double(productCount) / Double(columns)))
            return CGFloat(rows * 118) + CGFloat(max(0, rows - 1) * 12)
        case .simpleList:
            let productCount = products(for: categoryName).count
            guard productCount > 0 else { return 1 }
            return CGFloat(productCount * 102) + CGFloat(max(0, productCount - 1) * 10)
        }
    }

    private var compactPagerHeight: CGFloat {
        let currentIndex = categoryIndex(selectedCategory) ?? 0
        let visibleNames = categories.enumerated().compactMap { index, category in
            abs(index - currentIndex) <= 1 ? category.name : nil
        }
        let categoryHeights = visibleNames.map { productGridHeight(for: $0) }
        return max(categoryHeights.max() ?? 1, compactPagerMinimumHeight)
    }

    private var productPagerHeight: CGFloat {
        guard !isCompact else { return compactPagerHeight }
        guard let selectedCategory else { return 1 }
        return max(productGridHeight(for: selectedCategory), regularPagerMinimumHeight)
    }

    private func updateProductGridWidth(_ width: CGFloat) {
        let nextWidth = max(1, width - 14)
        guard abs(productGridWidth - nextWidth) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            productGridWidth = nextWidth
        }
    }

    private func columnSpan(for cardSize: POSCardSize) -> Int {
        guard isCompact else { return cardSize.columnSpan }

        return switch compactCardSize(cardSize) {
        case .small: 2
        case .medium: 2
        case .big: 4
        }
    }

    private func rowSpan(for cardSize: POSCardSize) -> Int {
        guard isCompact else { return cardSize.rowSpan }

        return switch compactCardSize(cardSize) {
        case .small: 2
        case .medium: 2
        case .big: 4
        }
    }

    private func compactCardSize(_ cardSize: POSCardSize) -> POSCardSize {
        cardSize == .big ? .big : .small
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

    private var productInsertionEdge: Edge {
        categorySlideDirection >= 0 ? .trailing : .leading
    }

    private var productRemovalEdge: Edge {
        categorySlideDirection >= 0 ? .leading : .trailing
    }

    private func categoryIndex(_ name: String?) -> Int? {
        guard let name else { return nil }
        return categories.firstIndex { $0.name == name }
    }

    private func selectCategory(_ name: String) {
        let currentIndex = categoryIndex(selectedCategory) ?? 0
        let nextIndex = categoryIndex(name) ?? currentIndex
        guard selectedCategory != name else { return }
        categorySlideDirection = nextIndex >= currentIndex ? 1 : -1
        selectedCategory = name
        productAnimationToken = UUID()
    }

    private func selectAdjacentCategory(offset: Int) {
        guard !isArrangeMode,
              categories.count > 1,
              let currentIndex = categoryIndex(selectedCategory) else {
            return
        }

        let nextIndex = currentIndex + offset
        guard categories.indices.contains(nextIndex) else {
            Haptics.impact(.light)
            return
        }

        selectCategory(categories[nextIndex].name)
        Haptics.selectionChanged()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        ScrollViewReader { categoryProxy in
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
                                                selectCategory(category.name)
                                                categoryProxy.scrollTo(category.name, anchor: .center)
                                            }
                                        } onArrange: {
                                            enterArrangeMode()
                                        }
                                        .id(category.name)
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
                            .onChange(of: selectedCategory) { _, categoryName in
                                guard let categoryName else { return }
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                                    categoryProxy.scrollTo(categoryName, anchor: .center)
                                }
                            }
                        }

                        if store.isRefreshing {
                            ProgressView()
                                .tint(accentColor)
                        }

                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 8)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))

                if !isArrangeMode, !categories.isEmpty {
                    POSSwipeCategoryPager(
                        pageCount: categories.count,
                        currentIndex: Binding(
                            get: { categoryIndex(selectedCategory) ?? 0 },
                            set: { newIndex in
                                guard categories.indices.contains(newIndex) else { return }
                                selectCategory(categories[newIndex].name)
                            }
                        ),
                        onSwipeActivity: {
                            suppressProductTapUntil = Date().addingTimeInterval(0.28)
                        }
                    ) { index, width in
                        productGrid(for: categories[index].name, fixedWidth: width)
                    }
                    .frame(
                        height: productPagerHeight,
                        alignment: .top
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    updateProductGridWidth(proxy.size.width)
                                }
                                .onChange(of: proxy.size.width) { _, width in
                                    updateProductGridWidth(width)
                                }
                        }
                    )
                    .contentShape(Rectangle())
                } else {
                    productGrid(for: selectedCategory ?? "")
                        .transition(.asymmetric(
                            insertion: .move(edge: productInsertionEdge),
                            removal: .move(edge: productRemovalEdge)
                        ))
                        .id(productAnimationToken)
                        .clipped()
                        .contentShape(Rectangle())
                        .animation(.spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.04), value: productAnimationToken)
                }
            } else {
                EmptyKitchenView()
            }
        }
        .contentShape(Rectangle())
        .sheet(item: $selectedProduct) { product in
            POSProductSheet(product: product, imageURL: store.imageURL(for: product), toppingCategoryOrder: toppingCategoryOrder, accentColor: accentColor) { toppings in
                store.add(product: product, toppings: toppings)
                selectedProduct = nil
            }
            .emberSheetChrome()
        }
        .onChange(of: store.bootstrap) { _, bootstrap in
            guard let catalog = bootstrap?.catalog else { return }
            syncArrangeOrders(catalog: catalog)
        }
        .onChange(of: displayStyle) { _, _ in
            productAnimationToken = UUID()
        }
        .onChange(of: categorySwipeCommand) { _, command in
            guard command.offset != 0 else { return }
            selectAdjacentCategory(offset: command.offset)
        }
        .onChange(of: isArrangeMode) { _, isArranging in
            if !isArranging {
                wobblePhase = false
                clearArrangeDragState()
            }
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
            wobblePhase: wobblePhase,
            isCompact: isCompact
        ) {
            handleProductTap(product)
        } onArrange: {
            enterArrangeMode()
        } onCycleSize: {
            cycleProductCardSize(product)
        }
    }

    @ViewBuilder
    private func productGrid(for categoryName: String, fixedWidth: CGFloat? = nil) -> some View {
        let categoryProducts = products(for: categoryName)

        switch displayStyle {
        case .productCard:
            let spacing: CGFloat = 14
            let gridWidth = fixedWidth.map { max(1, $0) } ?? layoutProductGridWidth
            let layout = productTilePlacements(products: categoryProducts, width: gridWidth, spacing: spacing)

            ZStack(alignment: .topLeading) {
                if fixedWidth == nil {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                productGridWidth = max(1, proxy.size.width)
                            }
                            .onChange(of: proxy.size.width) { _, width in
                                productGridWidth = max(1, width)
                            }
                        }
                }

                ForEach(layout.placements) { placement in
                    productTile(for: placement, in: layout.placements)
                }
            }
            .frame(width: fixedWidth, alignment: .topLeading)
            .frame(height: max(layout.height, 1), alignment: .topLeading)
        case .grabGrid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(categoryProducts) { product in
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
            .frame(width: fixedWidth, alignment: .topLeading)
        case .simpleList:
            LazyVStack(spacing: 10) {
                ForEach(categoryProducts) { product in
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
            .frame(width: fixedWidth, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func productTile(for placement: ProductTilePlacement, in placements: [ProductTilePlacement]) -> some View {
        let tile = posProductCard(for: placement.product)
            .frame(width: placement.width, height: placement.height)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .position(x: placement.x + (placement.width / 2), y: placement.y + (placement.height / 2))
            .offset(draggingProductID == placement.product.id ? draggingProductOffset : .zero)
            .zIndex(draggingProductID == placement.product.id ? 2 : 0)

        if isArrangeMode {
            tile.gesture(productCardDragGesture(for: placement, in: placements))
        } else {
            tile
        }
    }

    private func handleProductTap(_ product: POSProduct) {
        guard Date() >= suppressProductTapUntil else { return }

        if isArrangeMode {
            cycleProductCardSize(product)
        } else {
            selectedProduct = product
        }
    }

    private func productCardSize(for product: POSProduct) -> POSCardSize {
        let size = productCardSizes[product.id] ?? .small
        return isCompact ? compactCardSize(size) : size
    }

    private func cycleProductCardSize(_ product: POSProduct) {
        guard displayStyle == .productCard else {
            Haptics.impact(.light)
            return
        }

        var sizes = productCardSizes
        sizes[product.id] = isCompact
            ? (productCardSize(for: product) == .big ? .small : .big)
            : productCardSize(for: product).next

        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            productCardSizes = sizes
            productAnimationToken = UUID()
        }
        Haptics.selectionChanged()
    }

    private func productReorderModifier(for product: POSProduct) -> some ViewModifier {
        POSProductReorderModifier(
            productID: product.id,
            scope: arrangeScope(for: selectedCategory),
            isArranging: isArrangeMode,
            draggingProductID: $draggingProductID,
            lastDropTarget: $lastProductDropTarget,
            productIDsByScope: $arrangedProductIDsByScope,
            onBeginDrag: { enterArrangeMode() }
        )
    }

    private func productCardDragGesture(for placement: ProductTilePlacement, in placements: [ProductTilePlacement]) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isArrangeMode else { return }

                draggingProductID = placement.product.id
                draggingProductOffset = value.translation

                let currentCenter = CGPoint(
                    x: placement.x + (placement.width / 2) + value.translation.width,
                    y: placement.y + (placement.height / 2) + value.translation.height
                )

                guard let target = placements.first(where: { candidate in
                    candidate.product.id != placement.product.id &&
                    CGRect(x: candidate.x, y: candidate.y, width: candidate.width, height: candidate.height).contains(currentCenter)
                }) else {
                    return
                }

                reorderProduct(placement.product.id, before: target.product.id)
            }
            .onEnded { _ in
                draggingProductID = nil
                draggingProductOffset = .zero
                lastProductDropTarget = nil
            }
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
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isArrangeMode = true
            wobblePhase = true
        }
    }

    private func finishArrangeMode() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isArrangeMode = false
            wobblePhase = false
            clearArrangeDragState()
        }
    }

    private func clearArrangeDragState() {
        draggingCategoryName = nil
        draggingProductID = nil
        draggingProductOffset = .zero
        lastCategoryDropTarget = nil
        lastProductDropTarget = nil
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

    private func reorderProduct(_ draggingID: Int, before targetID: Int) {
        guard draggingID != targetID,
              lastProductDropTarget != targetID else {
            return
        }

        let scope = arrangeScope(for: selectedCategory)
        guard var order = arrangedProductIDsByScope[scope],
              let fromIndex = order.firstIndex(of: draggingID),
              let toIndex = order.firstIndex(of: targetID) else {
            return
        }

        lastProductDropTarget = targetID
        withAnimation(.snappy(duration: 0.16)) {
            order.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
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
    let isArranging: Bool
    @Binding var draggingProductID: Int?
    @Binding var lastDropTarget: Int?
    @Binding var productIDsByScope: [String: [Int]]
    let onBeginDrag: () -> Void

    func body(content: Content) -> some View {
        if isArranging {
            content
                .onDrag {
                    onBeginDrag()
                    draggingProductID = productID
                    return NSItemProvider(object: "\(productID)" as NSString)
                } preview: {
                    Color.clear
                        .frame(width: 1, height: 1)
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
        } else {
            content
        }
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
                    Text("#\(activeShift.id)")
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
    let onSignOff: () -> Void
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var drawerOwnerName: String? {
        guard let activeOperator = shift.activeOperator,
              activeOperator.id != `operator`.id else {
            return nil
        }

        return activeOperator.name
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 15) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 35, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 64, height: 64)
                        .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OPERATOR")
                            .font(GlacialFont.caption(.bold))
                            .tracking(2)
                            .foregroundStyle(accentColor)
                        Text(`operator`.name.uppercased())
                            .font(GlacialFont.custom(22, .medium))
                            .tracking(1.1)
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                        Text(`operator`.roleLabel)
                            .font(GlacialFont.caption2(.bold))
                            .tracking(1.4)
                            .foregroundStyle(`operator`.canAccessAdminFeatures ? accentColor : AppPalette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke((`operator`.canAccessAdminFeatures ? accentColor : AppPalette.line).opacity(0.55), lineWidth: 1)
                            )
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(drawerOwnerName == nil ? (shift.isOpen ? "SHIFT OPEN" : "SHIFT CLOSED") : "DRAWER BUSY")
                                .font(GlacialFont.subheadline(.medium))
                                .tracking(1.8)
                                .foregroundStyle(AppPalette.ink)
                            if let activeShift = shift.shift {
                                Text("#\(activeShift.id)")
                                    .font(GlacialFont.caption())
                                    .foregroundStyle(AppPalette.muted)
                            } else if let drawerOwnerName {
                                Text("\(drawerOwnerName) is currently serving.")
                                    .font(GlacialFont.caption(.semibold))
                                    .foregroundStyle(AppPalette.orange)
                            }
                        }

                        Spacer()

                        Text(drawerOwnerName == nil ? (shift.isOpen ? "ready" : "closed") : "busy")
                            .font(GlacialFont.caption(.bold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(drawerOwnerName == nil ? (shift.isOpen ? AppPalette.green : accentColor) : AppPalette.orange)
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
                    if drawerOwnerName != nil {
                        Text("\(drawerOwnerName ?? "Another operator") is currently serving. Close that shift before opening a new cash drawer.")
                            .font(GlacialFont.subheadline(.semibold))
                            .foregroundStyle(AppPalette.orange)
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                    } else if shift.isOpen {
                        POSShiftMenuButton(title: "CASH IN", icon: "plus", isSubmitting: isSubmitting, accentColor: accentColor, action: onCashIn)
                        POSShiftMenuButton(title: "CASH OUT", icon: "minus", isSubmitting: isSubmitting, accentColor: accentColor, action: onCashOut)
                        POSShiftMenuButton(title: "CLOSE SHIFT", icon: "lock", isSubmitting: isSubmitting, accentColor: accentColor, tone: .danger, action: onCloseShift)
                    } else {
                        POSShiftMenuButton(title: "OPEN SHIFT", icon: "lock.open", isSubmitting: isSubmitting, accentColor: accentColor, action: onOpenShift)
                    }

                    POSShiftMenuButton(title: "SIGN OFF", icon: "rectangle.portrait.and.arrow.right", isSubmitting: isSubmitting, accentColor: accentColor, tone: .danger, action: onSignOff)
                }

                Spacer()
            }
            .padding(20)
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                authenticationTopBar
            }
        }
    }

    private var authenticationTopBar: some View {
        ZStack {
            Text("AUTHENTICATION")
                .font(GlacialFont.subheadline(.medium))
                .tracking(2.4)
                .foregroundStyle(AppPalette.ink)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(AppPalette.background)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

private struct POSShiftLoadingSheet: View {
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(accentColor)

                Text("LOADING SHIFT")
                    .font(GlacialFont.subheadline(.medium))
                    .tracking(2)
                    .foregroundStyle(AppPalette.ink)

                Text("POS data is connecting.")
                    .font(GlacialFont.caption())
                    .foregroundStyle(AppPalette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppPalette.background.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                ZStack {
                    Text("SHIFT")
                        .font(GlacialFont.subheadline(.medium))
                        .tracking(2.4)
                        .foregroundStyle(AppPalette.ink)

                    HStack {
                        Spacer()
                        POSCloseIconButton {
                            dismiss()
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .background(AppPalette.background)
            }
        }
    }
}

private struct CompactPOSShiftDrawer: View {
    let `operator`: POSOperator
    let shift: POSShiftEnvelope
    let isSubmitting: Bool
    let accentColor: Color
    var bottomInset: CGFloat = 18
    let onDismiss: () -> Void
    let onOpenShift: () -> Void
    let onCashIn: () -> Void
    let onCashOut: () -> Void
    let onCloseShift: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SHIFT")
                            .font(GlacialFont.caption(.bold))
                            .tracking(2)
                            .foregroundStyle(accentColor)
                        Text(`operator`.name.uppercased())
                            .font(GlacialFont.title3(.semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                    }

                    Spacer()

                    POSCloseIconButton(action: onDismiss)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shift.isOpen ? "SHIFT OPEN" : "SHIFT CLOSED")
                                .font(GlacialFont.subheadline(.medium))
                                .tracking(1.6)
                                .foregroundStyle(AppPalette.ink)
                            if let activeShift = shift.shift {
                                Text("#\(activeShift.id)")
                                    .font(GlacialFont.caption())
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }

                        Spacer()

                        Text(shift.isOpen ? "READY" : "CLOSED")
                            .font(GlacialFont.caption(.bold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .foregroundStyle(shift.isOpen ? AppPalette.green : accentColor)
                            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let recap = shift.recap {
                        HStack(spacing: 8) {
                            POSShiftRecapTile(title: "ORDERS", value: "\(recap.orders)")
                            POSShiftRecapTile(title: "REVENUE", value: "\(Int(recap.revenue).formatted())")
                            POSShiftRecapTile(title: "CASH", value: "\(Int(recap.expectedCash).formatted())")
                        }
                    }
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.8), lineWidth: 1)
                )

                VStack(spacing: 9) {
                    if shift.isOpen {
                        POSShiftMenuButton(title: "CASH IN", icon: "plus", isSubmitting: isSubmitting, accentColor: accentColor, action: onCashIn)
                        POSShiftMenuButton(title: "CASH OUT", icon: "minus", isSubmitting: isSubmitting, accentColor: accentColor, action: onCashOut)
                        POSShiftMenuButton(title: "CLOSE SHIFT", icon: "lock", isSubmitting: isSubmitting, accentColor: accentColor, tone: .danger, action: onCloseShift)
                    } else {
                        POSShiftMenuButton(title: "OPEN SHIFT", icon: "lock.open", isSubmitting: isSubmitting, accentColor: accentColor, action: onOpenShift)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomInset)
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.88), value: shift.isOpen)
    }
}

private struct CompactFullScreenPanel<Content: View>: View {
    let accentColor: Color
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 104)
            .background(AppPalette.background.ignoresSafeArea())
            .ignoresSafeArea(edges: .bottom)
    }
}

private struct CompactPersistentBottomDrawer<Content: View>: View {
    let bottomInset: CGFloat
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)

                content
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: proxy.size.height * 0.82)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
                    .overlay(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
                            .stroke(.white.opacity(0.58), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
                    .padding(.horizontal, 10)
                    .padding(.bottom, bottomInset)
                    .onTapGesture {}
            }
        }
    }
}

private struct POSCloseIconButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 30, height: 30)
                .background(AppPalette.card, in: Circle())
                .overlay(
                    Circle()
                        .stroke(AppPalette.line.opacity(0.85), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
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
    let errorMessage: String?
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
            errorMessage: errorMessage,
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
    let errorMessage: String?
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
            errorMessage: errorMessage,
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
    let isSubmitting: Bool
    let errorMessage: String?
    let accentColor: Color
    let loadShift: () async -> POSShiftEnvelope?
    let submit: (Double?, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var shift: POSShiftEnvelope?
    @State private var isLoadingShift = true
    @State private var closingCash = ""
    @State private var notes = ""

    var body: some View {
        POSShiftFormShell(
            title: "CLOSE SHIFT",
            isSubmitting: isSubmitting,
            canSubmit: !isLoadingShift && shift != nil && (closingCash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedClosingCash != nil),
            errorMessage: errorMessage,
            accentColor: accentColor,
            submit: {
                await submit(parsedClosingCash, notes)
            }
        ) {
            if isLoadingShift {
                ProgressView("Loading current drawer totals…")
            } else if shift == nil {
                Button("Retry loading drawer totals") {
                    Task { await refreshShift() }
                }
                .tint(accentColor)
            }
            if let drawerSummary {
                VStack(spacing: 8) {
                    POSDrawerSummaryRow(title: "opening cash", amount: drawerSummary.openingCash)
                    POSDrawerSummaryRow(title: "cash sales", amount: drawerSummary.cashSales)
                    POSDrawerSummaryRow(title: "cash in", amount: drawerSummary.cashDeposited)
                    POSDrawerSummaryRow(title: "cash out", amount: -drawerSummary.cashWithdrawn)
                    Divider()
                    POSDrawerSummaryRow(title: "expected cash", amount: drawerSummary.expectedCash, isTotal: true)
                }
                .padding(14)
                .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
            }

            POSMoneyField(title: "closing cash", placeholder: "Optional", text: $closingCash)
            POSNotesField(title: "notes", placeholder: "Optional", text: $notes)
        }
        .task { await refreshShift() }
    }

    @MainActor
    private func refreshShift() async {
        isLoadingShift = true
        shift = nil
        shift = await loadShift()
        isLoadingShift = false
    }

    private var drawerSummary: POSDrawerSummary? {
        guard let shift else { return nil }

        let openingCash = shift.shift?.openingCash ?? 0
        let cashSales = shift.recap?.cashSales ?? 0
        let cashDeposited = shift.recap?.cashDeposited ?? 0
        let cashWithdrawn = shift.recap?.cashWithdrawn ?? 0
        let expectedCash = shift.recap?.expectedCash ?? (openingCash + cashSales + cashDeposited - cashWithdrawn)

        return POSDrawerSummary(
            openingCash: openingCash,
            cashSales: cashSales,
            cashDeposited: cashDeposited,
            cashWithdrawn: cashWithdrawn,
            expectedCash: expectedCash
        )
    }

    private var parsedClosingCash: Double? {
        POSMoneyParser.value(closingCash)
    }
}

private struct POSDrawerSummary: Equatable {
    let openingCash: Double
    let cashSales: Double
    let cashDeposited: Double
    let cashWithdrawn: Double
    let expectedCash: Double
}

private struct POSDrawerSummaryRow: View {
    let title: String
    let amount: Double
    var isTotal = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(GlacialFont.caption(isTotal ? .bold : .regular))
                .tracking(1.3)
                .foregroundStyle(isTotal ? AppPalette.ink : AppPalette.muted)
            Spacer()
            Text("\(Int(amount).formatted()) VND")
                .font(GlacialFont.subheadline(isTotal ? .semibold : .regular))
                .foregroundStyle(isTotal ? AppPalette.ink : AppPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
    }
}

private struct POSShiftFormShell<Content: View>: View {
    let title: String
    let isSubmitting: Bool
    let canSubmit: Bool
    let errorMessage: String?
    let accentColor: Color
    let submit: () async -> Bool
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    content
                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(GlacialFont.caption(.semibold))
                            .foregroundStyle(AppPalette.red)
                            .multilineTextAlignment(.leading)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppPalette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
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
                        POSRectActionLabel(
                            title: isSubmitting ? "SAVING" : "SAVE",
                            tint: accentColor,
                            isPrimary: true,
                            isLoading: isSubmitting,
                            fillsWidth: true
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(isSubmitting || !canSubmit)
                    .opacity(isSubmitting || !canSubmit ? 0.55 : 1)
                }
                .padding(20)
                .background(.white)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                formTopBar
            }
        }
    }

    private var formTopBar: some View {
        ZStack {
            Text(title)
                .font(GlacialFont.subheadline(.medium))
                .tracking(2.4)
                .foregroundStyle(AppPalette.ink)

            HStack {
                Spacer()
                if isCompact {
                    POSCloseIconButton {
                        dismiss()
                    }
                } else {
                    POSCheckoutTopAction(title: "CLOSE", tint: AppPalette.ink) {
                        dismiss()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(AppPalette.background)
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
                .foregroundStyle(AppPalette.ink)
                .foregroundColor(AppPalette.ink)
                .tint(AppPalette.orange)
                .keyboardType(.numberPad)
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                )
                .onChange(of: text) { _, newValue in
                    let formatted = POSMoneyParser.formattedInput(newValue)
                    if formatted != newValue {
                        text = formatted
                    }
                }
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
                .foregroundStyle(AppPalette.ink)
                .foregroundColor(AppPalette.ink)
                .tint(AppPalette.orange)
                .lineLimit(2...4)
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                )
        }
    }
}

private enum POSMoneyParser {
    static func formattedInput(_ text: String) -> String {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty, let value = Int(digits) else {
            return ""
        }

        return value.formatted()
    }

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

    var csvValues: [String] {
        split(separator: "|")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    var normalizedCustomerSearchValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }
}

private extension Array where Element == String {
    var csvStorageValue: String {
        joined(separator: "|")
    }
}

private extension UIImage {
    var logoAspectRatio: CGFloat {
        size.height > 0 ? max(0.1, size.width / size.height) : 2.8
    }

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

    func normalizedForPOSLogo() -> UIImage {
        let image = croppedToVisiblePixels() ?? self
        let maxSide: CGFloat = 1200
        let largestSide = max(image.size.width, image.size.height)
        let scale = largestSide > maxSide ? maxSide / largestSide : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func croppedToVisiblePixels(alphaThreshold: UInt8 = 8, whiteThreshold: UInt8 = 244) -> UIImage? {
        guard let cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                let alpha = pixels[offset + 3]
                let isOpaqueWhiteCanvas = alpha > alphaThreshold && red >= whiteThreshold && green >= whiteThreshold && blue >= whiteThreshold
                guard alpha > alphaThreshold, !isOpaqueWhiteCanvas else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard minX <= maxX, minY <= maxY else { return nil }

        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard cropRect.width < CGFloat(width) || cropRect.height < CGFloat(height),
              let cropped = cgImage.cropping(to: cropRect) else {
            return self
        }

        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
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
    let assetName: String

    var body: some View {
        GeometryReader { proxy in
            Image(assetName)
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
    let isCompact: Bool
    let action: () -> Void
    let onArrange: () -> Void
    let onCycleSize: () -> Void
    @State private var ignoresNextTap = false

    private var titleFont: Font {
        isCompact ? GlacialFont.subheadline(.semibold) : GlacialFont.headline(.semibold)
    }

    private var titlePadding: CGFloat {
        isCompact ? 10 : 14
    }

    private var arrangeLongPressDuration: Double {
        isCompact ? 0.62 : 0.36
    }

    var body: some View {
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
                        .font(titleFont)
                        .tracking(isCompact ? 0.7 : 1.1)
                        .foregroundStyle(.white)
                        .lineLimit(isCompact ? 2 : 1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.78)
                }
                .padding(titlePadding)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)

                productActionControl
                    .padding(isCompact ? 8 : 12)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(quantityInCart > 0 ? accentColor.opacity(0.8) : AppPalette.line.opacity(0.8), lineWidth: 1)
        )
        .onTapGesture {
            if ignoresNextTap {
                ignoresNextTap = false
                return
            }

            action()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: arrangeLongPressDuration, maximumDistance: 6)
                .onEnded { _ in
                    ignoresNextTap = true
                    onArrange()
                }
        )
    }

    @ViewBuilder
    private var productActionControl: some View {
        HStack {
            if isArranging {
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
                .buttonStyle(NoHighlightButtonStyle())
            }

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
    @State private var ignoresNextTap = false

    var body: some View {
        Button {
            if ignoresNextTap {
                ignoresNextTap = false
                return
            }

            action()
        } label: {
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
        }
        .buttonStyle(NoHighlightButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.36, maximumDistance: 6)
                .onEnded { _ in
                    ignoresNextTap = true
                    onArrange()
                }
        )
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
    @State private var ignoresNextTap = false

    var body: some View {
        Button {
            if ignoresNextTap {
                ignoresNextTap = false
                return
            }

            action()
        } label: {
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
        }
        .buttonStyle(NoHighlightButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.36, maximumDistance: 6)
                .onEnded { _ in
                    ignoresNextTap = true
                    onArrange()
                }
        )
    }
}

private final class POSProductImageCache {
    static let shared = POSProductImageCache()

    private let cache = NSCache<NSURL, UIImage>()
    private let directoryName = "POSProductImageCache"

    private init() {}

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    func cachedFileURL(for url: URL) -> URL? {
        guard !url.isFileURL,
              let fileURL = fileURL(for: url),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return fileURL
    }

    func prewarm(urls: [URL], limit: Int = 18) async {
        let uniqueURLs = Array(Set(urls)).prefix(limit)

        await withTaskGroup(of: (URL, UIImage?).self) { group in
            for url in uniqueURLs where image(for: url) == nil {
                group.addTask {
                    let image: UIImage?
                    if url.isFileURL {
                        image = UIImage(contentsOfFile: url.path)
                    } else if let cachedFile = await self.cachedFileURL(for: url) {
                        image = UIImage(contentsOfFile: cachedFile.path)
                    } else if let data = try? Data(contentsOf: url) {
                        image = UIImage(data: data)
                        if image != nil {
                            await self.storeDownloadedData(data, for: url)
                        }
                    } else {
                        image = nil
                    }

                    return (url, image)
                }
            }

            for await (url, image) in group {
                guard let image else { continue }
                store(image, for: url)
            }
        }
    }

    func storeDownloadedData(_ data: Data, for url: URL) {
        guard let fileURL = fileURL(for: url) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func fileURL(for url: URL) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".img"
        return caches.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(name)
    }
}

private struct POSProductImage: View {
    let url: URL?
    @State private var loadedImage: UIImage?
    @State private var loadedURL: URL?

    private var cachedImage: UIImage? {
        guard let url else { return nil }
        return POSProductImageCache.shared.image(for: url)
    }

    private var currentImage: UIImage? {
        cachedImage ?? (loadedURL == url ? loadedImage : nil)
    }

    var body: some View {
        if let image = currentImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .allowsHitTesting(false)
        } else {
            ZStack {
                POSProductImageFallback()

                if url != nil {
                    ProgressView()
                        .tint(AppPalette.orange)
                }
            }
            .task(id: url) {
                await loadImage()
            }
            .allowsHitTesting(false)
        }
    }

    private func loadImage() async {
        guard let url else {
            loadedURL = nil
            loadedImage = nil
            return
        }

        if let image = POSProductImageCache.shared.image(for: url) {
            loadedURL = url
            loadedImage = image
            return
        }

        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            if url.isFileURL {
                return UIImage(contentsOfFile: url.path)
            }

            if let cachedFile = await POSProductImageCache.shared.cachedFileURL(for: url) {
                return UIImage(contentsOfFile: cachedFile.path)
            }

            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            await POSProductImageCache.shared.storeDownloadedData(data, for: url)
            return UIImage(data: data)
        }.value

        guard let image else { return }
        POSProductImageCache.shared.store(image, for: url)
        loadedURL = url
        loadedImage = image
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
    let toppingCategoryOrder: [String]
    let accentColor: Color
    let actionTitle: String
    let onAdd: ([POSTopping]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedToppingIDs = Set<Int>()

    init(
        product: POSProduct,
        imageURL: URL?,
        toppingCategoryOrder: [String],
        accentColor: Color,
        initialToppings: [POSTopping] = [],
        actionTitle: String = "ADD TO CART",
        onAdd: @escaping ([POSTopping]) -> Void
    ) {
        self.product = product
        self.imageURL = imageURL
        self.toppingCategoryOrder = toppingCategoryOrder
        self.accentColor = accentColor
        self.actionTitle = actionTitle
        self.onAdd = onAdd
        _selectedToppingIDs = State(initialValue: Set(initialToppings.map(\.id)))
    }

    private var selectedToppings: [POSTopping] {
        product.toppings.filter { selectedToppingIDs.contains($0.id) }
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
            .sorted { lhs, rhs in
                let lhsIndex = toppingCategoryOrder.firstIndex(of: lhs.0)
                let rhsIndex = toppingCategoryOrder.firstIndex(of: rhs.0)

                switch (lhsIndex, rhsIndex) {
                case let (lhsIndex?, rhsIndex?):
                    return lhsIndex < rhsIndex
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.0 < rhs.0
                }
            }
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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                productSheetTopBar
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onAdd(selectedToppings)
                } label: {
                    Text(actionTitle)
                        .font(GlacialFont.caption(.bold))
                        .tracking(2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 18)
                        .foregroundStyle(.white)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(accentColor.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(20)
                .background(.white)
            }
        }
    }

    private var productSheetTopBar: some View {
        ZStack {
            Text("CUSTOMIZE")
                .font(GlacialFont.subheadline(.medium))
                .tracking(2.4)
                .foregroundStyle(AppPalette.ink)

            HStack {
                Spacer()
                POSCloseIconButton {
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.white)
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
    let tickets: [POSDraftTicket]
    let activeTicketID: UUID
    let total: Double
    let baseURL: String
    let token: String
    let posSessionToken: String
    let isSubmitting: Bool
    let accentColor: Color
    let toppingCategoryOrder: [String]
    let productImageURL: (POSProduct) -> URL?
    let onIncrement: (POSCartLine) -> Void
    let onDecrement: (POSCartLine) -> Void
    let onRemove: (POSCartLine) -> Void
    let onClearCart: () -> Void
    let onNewTicket: () -> Void
    let onSwitchTicket: (POSDraftTicket) -> Void
    let defaultPrintReceipt: (POSOrderSource) -> Bool
    let printQuotation: (POSQuotationSnapshot) async -> PrintReceiptResult
    let activeRewardRedemption: POSRewardRedemption?
    let activeRewardQuote: POSRewardQuote?
    let submissionError: String?
    let onMarketplacePriceChange: (POSCartLine, Double?) -> Void
    let onToppingsChange: (POSCartLine, [POSTopping]) -> Void
    let scanRewardToken: (String) async throws -> Void
    let quoteRewardSale: (POSPaymentMethod, POSOrderSource, String, POSCustomer?, Double, String, String?) async throws -> POSRewardQuote
    let clearRewardRedemption: () -> Void
    let clearRewardQuote: () -> Void
    let submit: (POSPaymentMethod, POSOrderSource, String, POSCustomer?, Double, String, Double, Bool, String?, String?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var paymentMethod: POSPaymentMethod = .cash
    @State private var orderSource: POSOrderSource = .inStore
    @State private var externalReference = ""
    @State private var discountPercent = ""
    @State private var cashReceived = ""
    @State private var notes = ""
    @State private var selectedCustomer: POSCustomer?
    @State private var shouldPrintReceipt = true
    @State private var isPrintingQuotation = false
    @State private var quotationMessage: String?
    @State private var customerSearch = ""
    @State private var customerResults: [POSCustomer] = []
    @State private var customerError: String?
    @State private var isSearchingCustomer = false
    @State private var isCreatingCustomer = false
    @State private var isCreateCustomerOpen = false
    @State private var newCustomerName = ""
    @State private var newCustomerPhone = ""
    @State private var newCustomerEmail = ""
    @State private var pendingCartReset: POSCartResetAction?
    @State private var editingToppingsLine: POSCartLine?
    @State private var isToppingLinePickerOpen = false
    @State private var isRewardScannerOpen = false
    @State private var isScanningReward = false
    @State private var isQuotingReward = false
    @State private var submissionFailed = false
    @State private var rewardRedemptionError: String?
    @State private var selectedRewardLineID: String?
    @State private var checkoutValidationMessage: String?
    @State private var customerSearchTask: Task<Void, Never>?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var parsedDiscountPercent: Double {
        let normalized = discountPercent
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Double(normalized) ?? 0
        return max(0, min(value, 100))
    }

    private var discountAmount: Double {
        checkoutSubtotal * parsedDiscountPercent / 100
    }

    private var isMarketplaceOrder: Bool {
        orderSource.isMarketplace
    }

    private var trimmedExternalReference: String {
        externalReference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCompleteCheckout: Bool {
        !isMarketplaceOrder || !trimmedExternalReference.isEmpty
    }

    private var checkoutSubtotal: Double {
        lines.reduce(0) { $0 + $1.lineTotal(for: orderSource) }
    }

    private var editableToppingLines: [POSCartLine] {
        lines.filter { !$0.product.toppings.isEmpty }
    }

    private var grossTotal: Double {
        max(0, checkoutSubtotal - discountAmount)
    }

    private var marketplaceDeduction: Double {
        isMarketplaceOrder ? POSMarketplaceFees.deductionAmount(grossTotal) : 0
    }

    private var finalTotal: Double {
        isMarketplaceOrder ? POSMarketplaceFees.actualReceived(grossTotal) : grossTotal
    }

    private var payableTotal: Double {
        activeRewardQuote?.finalPayableTotal ?? finalTotal
    }

    private var eligibleRewardLines: [POSCartLine] {
        lines.filter { $0.product.freeRewardEligibility != nil }
    }

    // Only inputs that affect the server preview trigger a refresh. Notes and cash tender do not.
    private var rewardPreviewContext: Data? {
        guard let reward = activeRewardRedemption else { return nil }
        let selected = eligibleRewardLines.contains(where: { $0.id == selectedRewardLineID })
            ? selectedRewardLineID : (eligibleRewardLines.count == 1 ? eligibleRewardLines.first?.id : nil)
        let request = POSRewardQuoteRequest(
            cart: lines.map { POSSaleCartItem(line: $0) }, paymentMethod: paymentMethod.rawValue,
            orderSource: orderSource.rawValue, externalOrderReference: trimmedExternalReference,
            customerID: checkoutCustomerForSubmission?.id ?? reward.customerID,
            discountPercent: parsedDiscountPercent, notes: nil,
            rewardRedemptionSessionID: reward.sessionID, rewardLineKey: selected, checkoutToken: ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(request)
    }

    private var checkoutBlockingMessage: String? {
        rewardRedemptionError ?? checkoutValidationMessage
            ?? (submissionFailed ? (submissionError ?? "Sale could not be completed. Please try again.") : nil)
    }

    private var selectedRewardLineKeyForSubmission: String? {
        activeRewardQuote?.eligibleProduct?.lineKey ?? selectedRewardLineID
    }

    private var parsedCashReceived: Double? {
        POSMoneyParser.value(cashReceived)
    }

    private var cashChange: Double? {
        guard paymentMethod == .cash, let parsedCashReceived else { return nil }
        return parsedCashReceived - payableTotal
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sourceSelector

                        if orderSource != .inStore {
                            marketplaceReferenceSection
                        }

                        ticketSwitcher
                        recapSection
                        quotationSection
                        customerSection
                        rewardRedemptionSection
                        printReceiptSection

                        paymentSelector
                        cashBackSection
                        discountSection
                        notesSection
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)

                VStack(spacing: 12) {
                    Divider()
                    VStack(spacing: 6) {
                        POSCheckoutTotalRow(title: isMarketplaceOrder ? "marketplace gross" : "subtotal", value: checkoutSubtotal)
                        if parsedDiscountPercent > 0 {
                            POSCheckoutTotalRow(title: "discount \(String(format: "%.1f", parsedDiscountPercent))%", value: -discountAmount, tint: accentColor)
                        }
                        if isMarketplaceOrder {
                            POSCheckoutTotalRow(title: "grab/shopee deduction", value: -marketplaceDeduction, tint: AppPalette.red)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text("TOTAL")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2)
                                .foregroundStyle(AppPalette.muted)
                            Spacer()
                            Text("\(Int(payableTotal).formatted()) VND")
                                .font(GlacialFont.custom(24, .semibold))
                                .foregroundStyle(AppPalette.ink)
                        }
                    }

                    if let message = checkoutBlockingMessage {
                        Text(message)
                            .font(GlacialFont.caption(.semibold))
                            .foregroundStyle(AppPalette.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("pos-checkout-error")
                    }
                    if isQuotingReward {
                        Label("Updating reward total…", systemImage: "clock")
                            .font(GlacialFont.caption())
                    }
                    Button {
                        guard !isQuotingReward, !isScanningReward, !isSubmitting else { return }
                        guard canCompleteCheckout else {
                            checkoutValidationMessage = "Enter the \(orderSource.label) reference before completing."
                            Haptics.notification(.error)
                            return
                        }

                        guard activeRewardRedemption == nil || activeRewardQuote != nil else {
                            Task { await previewRewardTotal() }
                            return
                        }

                        checkoutValidationMessage = nil
                        submissionFailed = false
                        Task {
                            let attachedCustomer = checkoutCustomerForSubmission
                            let didSubmit = await submit(
                                paymentMethod,
                                orderSource,
                                trimmedExternalReference,
                                attachedCustomer,
                                parsedDiscountPercent,
                                notes,
                                payableTotal,
                                shouldPrintReceipt,
                                activeRewardRedemption?.sessionID,
                                selectedRewardLineKeyForSubmission
                            )
                            if didSubmit {
                                dismiss()
                            } else {
                                submissionFailed = true
                            }
                        }
                    } label: {
                        POSRectActionLabel(
                            title: isSubmitting ? "COMPLETING" : (isQuotingReward ? "UPDATING TOTAL" : (activeRewardRedemption != nil && activeRewardQuote == nil ? "REVIEW REWARD TOTAL" : "COMPLETE")),
                            tint: accentColor,
                            isPrimary: true,
                            isLoading: isSubmitting,
                            fillsWidth: true
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting || isQuotingReward || isScanningReward)
                    .opacity(isSubmitting || isQuotingReward || isScanningReward ? 0.72 : 1)
                }
                .padding(20)
                .background(.white)
            }
            .background(AppPalette.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                checkoutTopBar
            }
            .confirmationDialog(
                pendingCartReset?.title ?? "",
                isPresented: Binding(
                    get: { pendingCartReset != nil },
                    set: { if !$0 { pendingCartReset = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pendingCartReset {
                    Button(pendingCartReset.confirmTitle, role: pendingCartReset.role) {
                        pendingCartReset.perform(
                            clearCart: onClearCart,
                            newTicket: onNewTicket
                        )
                        self.pendingCartReset = nil
                        if pendingCartReset.shouldDismiss {
                            dismiss()
                        }
                    }
                }
                Button("KEEP CART", role: .cancel) {
                    pendingCartReset = nil
                }
            } message: {
                Text(pendingCartReset?.message ?? "")
            }
            .confirmationDialog(
                "Edit toppings",
                isPresented: $isToppingLinePickerOpen,
                titleVisibility: .visible
            ) {
                ForEach(editableToppingLines) { line in
                    Button(line.product.name) {
                        editingToppingsLine = line
                    }
                }

                Button("CANCEL", role: .cancel) {}
            } message: {
                Text("Choose the item to customize.")
            }
            .onChange(of: orderSource) { _, newSource in
                checkoutValidationMessage = nil

                if newSource != .inStore {
                    paymentMethod = .bank
                    cashReceived = ""
                } else {
                    paymentMethod = .cash
                }

                selectedRewardLineID = nil
                shouldPrintReceipt = defaultPrintReceipt(newSource)
            }
            .task(id: rewardPreviewContext) {
                submissionFailed = false
                rewardRedemptionError = nil
                guard activeRewardRedemption != nil else { return }
                clearRewardQuote()
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    while isQuotingReward || isScanningReward {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try Task.checkCancellation()
                    guard activeRewardQuote == nil else { return }
                    await previewRewardTotal(automatic: true)
                } catch { /* A newer checkout state owns the next preview. */ }
            }
            .onAppear {
                shouldPrintReceipt = defaultPrintReceipt(orderSource)
            }
            .sheet(item: $editingToppingsLine) { line in
                POSProductSheet(
                    product: line.product,
                    imageURL: productImageURL(line.product),
                    toppingCategoryOrder: toppingCategoryOrder,
                    accentColor: accentColor,
                    initialToppings: line.toppings,
                    actionTitle: "UPDATE CART"
                ) { toppings in
                    onToppingsChange(line, toppings)
                    editingToppingsLine = nil
                }
                .emberSheetChrome()
            }
            .sheet(isPresented: $isRewardScannerOpen) {
                POSRewardScannerSheet(accentColor: accentColor) { token in
                    await redeemScannedRewardToken(token)
                }
            }
        }
    }

    private func openToppingEditor() {
        let editableLines = editableToppingLines

        if editableLines.count == 1 {
            editingToppingsLine = editableLines[0]
        } else if editableLines.count > 1 {
            isToppingLinePickerOpen = true
        }
    }

    private var checkoutCustomerForSubmission: POSCustomer? {
        if let selectedCustomer {
            return selectedCustomer
        }

        let normalizedSearch = customerSearch.normalizedCustomerSearchValue
        guard !normalizedSearch.isEmpty else { return nil }

        return customerResults.first { customer in
            customer.name.normalizedCustomerSearchValue == normalizedSearch
                || customer.phone?.normalizedCustomerSearchValue == normalizedSearch
                || customer.email?.normalizedCustomerSearchValue == normalizedSearch
        }
    }

    private var checkoutTopBar: some View {
        HStack(spacing: 8) {
            Spacer()

            POSCheckoutTopAction(title: "NEW TICKET", tint: AppPalette.ink) {
                onNewTicket()
                dismiss()
            }
            .disabled(isSubmitting)
            .opacity(isSubmitting ? 0.38 : 1)

            if isCompact {
                POSCloseIconButton {
                    dismiss()
                }
            } else {
                POSCheckoutTopAction(title: "CLOSE", tint: AppPalette.ink) {
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(AppPalette.background)
    }

    private var ticketSwitcher: some View {
        Group {
            if tickets.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(tickets) { ticket in
                            Button {
                                onSwitchTicket(ticket)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ticket.title)
                                        .font(GlacialFont.caption(.bold))
                                        .tracking(1.5)
                                    Text("\(ticket.itemCount) \(ticket.itemCount == 1 ? "ITEM" : "ITEMS")")
                                        .font(GlacialFont.caption2(.bold))
                                        .tracking(1.1)
                                        .opacity(0.72)
                                }
                                .foregroundStyle(ticket.id == activeTicketID ? .white : AppPalette.ink)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(ticket.id == activeTicketID ? accentColor : .white, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(ticket.id == activeTicketID ? accentColor.opacity(0.18) : AppPalette.line.opacity(0.82), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private var recapSection: some View {
        POSCheckoutChoiceGroup(title: "order recap") {
            HStack(spacing: 12) {
                Button {
                    openToppingEditor()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .bold))
                        Text("EDIT TOPPINGS")
                    }
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.2)
                    .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                .disabled(editableToppingLines.isEmpty || isSubmitting)
                .opacity(editableToppingLines.isEmpty || isSubmitting ? 0.34 : 1)

                Button {
                    pendingCartReset = .clearCart
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .bold))
                        Text("CLEAR CART")
                    }
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppPalette.red)
                }
                .buttonStyle(.plain)
                .disabled(lines.isEmpty || isSubmitting)
            }
        } content: {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(lines.reduce(0) { $0 + $1.quantity }) \(lines.reduce(0) { $0 + $1.quantity } == 1 ? "ITEM" : "ITEMS")")
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.7)
                        .foregroundStyle(AppPalette.muted)

                    Spacer()
                }
                .padding(.bottom, lines.isEmpty ? 0 : 12)

                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    POSCheckoutRecapLine(
                        index: index + 1,
                        line: line,
                        imageURL: productImageURL(line.product),
                        accentColor: accentColor,
                        onIncrement: { onIncrement(line) },
                        onDecrement: { decrement(line) },
                        onRemove: { remove(line) },
                        orderSource: orderSource,
                        onMarketplacePriceChange: { price in
                            onMarketplacePriceChange(line, price)
                        }
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

    private func decrement(_ line: POSCartLine) {
        onDecrement(line)
        if line.quantity <= 1 && lines.count <= 1 {
            dismiss()
        }
    }

    private func remove(_ line: POSCartLine) {
        onRemove(line)
        if lines.count <= 1 {
            dismiss()
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

    private var marketplaceReferenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("order reference")
                .font(GlacialFont.caption(.bold))
                .tracking(1.5)
                .foregroundStyle(AppPalette.muted)
            TextField("Grab / Shopee code", text: $externalReference)
                .font(GlacialFont.subheadline())
                .foregroundStyle(AppPalette.ink)
                .foregroundColor(AppPalette.ink)
                .tint(accentColor)
                .textInputAutocapitalization(.characters)
                .onChange(of: externalReference) { _, _ in
                    clearRewardQuote()
                    checkoutValidationMessage = nil
                }
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                )

            if let checkoutValidationMessage, isMarketplaceOrder {
                Text(checkoutValidationMessage)
                    .font(GlacialFont.caption(.semibold))
                    .foregroundStyle(AppPalette.red)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var quotationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                // Capture values before starting the task; editing remains independent of printing.
                let snapshot = POSQuotationSnapshot(
                    items: lines.map { line in
                        POSQuotationSnapshot.Item(
                            name: line.product.name,
                            sku: nil,
                            category: nil,
                            quantity: line.quantity,
                            baseUnitPrice: line.product.price,
                            unitPrice: line.unitPrice(for: orderSource),
                            lineTotal: line.lineTotal(for: orderSource),
                            toppings: line.toppings.map { topping in
                                PrintReceiptTopping(
                                    name: topping.name,
                                    sku: nil,
                                    category: nil,
                                    quantity: line.quantity,
                                    unitPrice: topping.price,
                                    lineTotal: topping.price * Double(line.quantity)
                                )
                            }
                        )
                    },
                    subtotal: checkoutSubtotal,
                    discount: activeRewardQuote?.manualDiscount ?? discountAmount,
                    marketplaceDeduction: marketplaceDeduction,
                    rewardDiscount: activeRewardQuote?.rewardDiscount ?? 0,
                    total: payableTotal
                )
                isPrintingQuotation = true
                quotationMessage = nil
                Task {
                    let result = await printQuotation(snapshot)
                    switch result {
                    case .printed:
                        quotationMessage = "Quotation sent to printer."
                    case .skipped:
                        quotationMessage = "Quotation not printed."
                    case .failed(let message):
                        quotationMessage = "Quotation not printed. \(message)"
                    }
                    isPrintingQuotation = false
                }
            } label: {
                Label(isPrintingQuotation ? "Printing Quotation…" : "Print Quotation", systemImage: "printer")
                    .font(GlacialFont.subheadline(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(12)
            }
            .buttonStyle(.bordered)
            .tint(accentColor)
            .disabled(lines.isEmpty || isPrintingQuotation)

            if let quotationMessage {
                Text(quotationMessage)
                    .font(GlacialFont.caption())
                    .foregroundStyle(AppPalette.muted)
            }
        }
    }

    private var printReceiptSection: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                shouldPrintReceipt.toggle()
            }
            Haptics.selectionChanged()
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(shouldPrintReceipt ? accentColor.opacity(0.14) : AppPalette.card)
                        .frame(width: 42, height: 42)

                    Image(systemName: shouldPrintReceipt ? "printer.fill" : "printer")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(shouldPrintReceipt ? accentColor : AppPalette.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("PRINT RECEIPT")
                        .font(GlacialFont.subheadline(.semibold))
                        .tracking(1.6)
                        .foregroundStyle(AppPalette.ink)

                    Text(shouldPrintReceipt ? "Receipt will print after complete." : "No receipt for this sale.")
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer()

                ZStack(alignment: shouldPrintReceipt ? .trailing : .leading) {
                    Capsule()
                        .fill(shouldPrintReceipt ? accentColor.opacity(0.24) : AppPalette.line.opacity(0.65))
                        .frame(width: 52, height: 30)

                    Circle()
                        .fill(shouldPrintReceipt ? accentColor : .white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                        .padding(3)
                }
                .frame(width: 52, height: 30)
            }
            .padding(13)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(shouldPrintReceipt ? accentColor.opacity(0.42) : AppPalette.line.opacity(0.75), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var rewardRedemptionSection: some View {
        POSCheckoutChoiceGroup(title: "free fitbites") {
            VStack(alignment: .leading, spacing: 12) {
                if let activeRewardRedemption {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "gift.fill")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(accentColor)
                            .frame(width: 36, height: 36)
                            .background(accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(activeRewardRedemption.rewardName)
                                .font(GlacialFont.subheadline(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text(activeRewardRedemption.customerName ?? "Customer reward reserved")
                                .font(GlacialFont.caption())
                                .foregroundStyle(AppPalette.muted)
                            if let policyDescription = activeRewardRedemption.policyDescription {
                                Text(policyDescription)
                                    .font(GlacialFont.caption())
                                    .foregroundStyle(AppPalette.muted)
                            }
                            if let expiresAt = activeRewardRedemption.reservationExpiresAt {
                                Text("Reserved until \(expiresAt)")
                                    .font(GlacialFont.caption2(.semibold))
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }

                        Spacer()

                        Button("clear") {
                            selectedRewardLineID = nil
                            clearRewardRedemption()
                        }
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(accentColor)
                    }
                    .padding(12)
                    .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("1 FREE REWARD")
                            .font(GlacialFont.caption(.bold))
                            .tracking(1.6)
                            .foregroundStyle(AppPalette.ink)
                        Text("Choose one Daily Go, Daily Classic, or standard coffee")
                            .font(GlacialFont.caption())
                            .foregroundStyle(AppPalette.muted)

                        if eligibleRewardLines.isEmpty {
                            Text("Add an eligible item to the cart.")
                                .font(GlacialFont.caption(.semibold))
                                .foregroundStyle(AppPalette.red)
                        } else {
                            ForEach(eligibleRewardLines) { line in
                                Button {
                                    guard selectedRewardLineID != line.id else { return }
                                    selectedRewardLineID = line.id
                                    clearRewardQuote()
                                    Haptics.selectionChanged()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selectedRewardLineID == line.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedRewardLineID == line.id ? accentColor : AppPalette.muted)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(line.product.name)
                                                .font(GlacialFont.caption(.semibold))
                                                .foregroundStyle(AppPalette.ink)
                                            Text("\(Int(line.product.price).formatted()) VND base")
                                                .font(GlacialFont.caption2())
                                                .foregroundStyle(AppPalette.muted)
                                        }
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background(selectedRewardLineID == line.id ? accentColor.opacity(0.10) : AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                    )

                    if let activeRewardQuote {
                        VStack(spacing: 8) {
                            POSCheckoutTotalRow(title: "subtotal", value: activeRewardQuote.subtotal)
                            POSCheckoutTotalRow(title: "free fitbites", value: -activeRewardQuote.rewardDiscount, tint: accentColor)
                            if activeRewardQuote.manualDiscount > 0 {
                                POSCheckoutTotalRow(title: "manual discount", value: -activeRewardQuote.manualDiscount, tint: accentColor)
                            }
                            if activeRewardQuote.paidAddOns > 0 {
                                POSCheckoutTotalRow(title: "paid add-ons", value: activeRewardQuote.paidAddOns)
                            }
                            HStack(alignment: .firstTextBaseline) {
                                Text("PAYABLE")
                                    .font(GlacialFont.caption(.bold))
                                    .tracking(1.7)
                                    .foregroundStyle(AppPalette.muted)
                                Spacer()
                                Text("\(Int(activeRewardQuote.finalPayableTotal).formatted()) VND")
                                    .font(GlacialFont.title3(.semibold))
                                    .foregroundStyle(AppPalette.ink)
                            }
                        }
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                        )
                    } else {
                        Text("Preview required before payment.")
                            .font(GlacialFont.caption(.semibold))
                            .foregroundStyle(AppPalette.muted)
                    }
                }

                if activeRewardRedemption != nil {
                    Button {
                        Task { await previewRewardTotal() }
                    } label: {
                        HStack {
                            if isQuotingReward {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "checkmark.seal")
                            }
                            Text(isQuotingReward ? "PREVIEWING" : "PREVIEW PAYABLE TOTAL")
                        }
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.6)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(AppPalette.ink, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(isQuotingReward || lines.isEmpty)
                }

                Button {
                    isRewardScannerOpen = true
                    rewardRedemptionError = nil
                } label: {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                        Text(activeRewardRedemption == nil ? "SCAN REWARD QR" : "SCAN ANOTHER QR")
                    }
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.6)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isScanningReward)

                if isScanningReward || isQuotingReward {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(accentColor)
                        Text(isQuotingReward ? "Previewing total with Laravel..." : "Checking reward with Laravel...")
                            .font(GlacialFont.caption())
                            .foregroundStyle(AppPalette.muted)
                    }
                }

                if let rewardRedemptionError {
                    Text(rewardRedemptionError)
                        .font(GlacialFont.caption(.semibold))
                        .foregroundStyle(AppPalette.red)
                }
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

    @ViewBuilder
    private var cashBackSection: some View {
        if paymentMethod == .cash {
            POSCheckoutChoiceGroup(title: "cash back") {
                VStack(alignment: .leading, spacing: 12) {
                    POSMoneyField(title: "cash received", placeholder: "\(Int(payableTotal).formatted())", text: $cashReceived)

                    HStack(alignment: .firstTextBaseline) {
                        Text(cashChangeText.title)
                            .font(GlacialFont.caption(.bold))
                            .tracking(1.7)
                            .foregroundStyle(AppPalette.muted)
                        Spacer()
                        Text(cashChangeText.value)
                            .font(GlacialFont.title3(.semibold))
                            .foregroundStyle(cashChangeText.color)
                    }
                    .padding(14)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var cashChangeText: (title: String, value: String, color: Color) {
        guard let cashChange else {
            return ("CHANGE", "ENTER CASH", AppPalette.muted)
        }

        if cashChange >= 0 {
            return ("CHANGE", "\(Int(cashChange).formatted()) VND", accentColor)
        }

        return ("REMAINING", "\(Int(abs(cashChange)).formatted()) VND", AppPalette.red)
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
                            POSLoyaltyStarsView(customer: selectedCustomer, accentColor: accentColor)
                        }
                        Spacer()
                        Button("clear") {
                            clearSelectedCustomer()
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
                        .foregroundStyle(AppPalette.ink)
                        .foregroundColor(AppPalette.ink)
                        .tint(accentColor)
                        .textInputAutocapitalization(.words)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                        )
                        .onSubmit {
                            Task { await searchCustomers(showEmptyMessage: true) }
                        }
                        .onChange(of: customerSearch) { _, newValue in
                            scheduleCustomerSuggestions(for: newValue)
                        }

                    Button {
                        Task { await searchCustomers(showEmptyMessage: true) }
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
                                attachCustomer(customer)
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
                            .foregroundStyle(AppPalette.ink)
                            .foregroundColor(AppPalette.ink)
                            .tint(accentColor)
                            .textInputAutocapitalization(.words)
                        TextField("phone number", text: $newCustomerPhone)
                            .foregroundStyle(AppPalette.ink)
                            .foregroundColor(AppPalette.ink)
                            .tint(accentColor)
                            .keyboardType(.phonePad)
                        TextField("email optional", text: $newCustomerEmail)
                            .foregroundStyle(AppPalette.ink)
                            .foregroundColor(AppPalette.ink)
                            .tint(accentColor)
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
                    .foregroundStyle(AppPalette.ink)
                    .foregroundColor(AppPalette.ink)
                    .tint(accentColor)
                    .keyboardType(.decimalPad)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                    )
                    .onChange(of: discountPercent) { _, _ in
                        clearRewardQuote()
                    }
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
                .foregroundStyle(AppPalette.ink)
                .foregroundColor(AppPalette.ink)
                .tint(accentColor)
                .lineLimit(2...4)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                )
        }
    }

    private func sourcePill(_ source: POSOrderSource) -> some View {
        POSCheckoutPill(title: source.label, isSelected: orderSource == source, accentColor: accentColor) {
            withAnimation(.smooth(duration: 0.24)) {
                guard orderSource != source else { return }
                orderSource = source
                selectedRewardLineID = nil
                clearRewardQuote()
            }
        }
    }

    private func paymentPill(_ method: POSPaymentMethod) -> some View {
        POSCheckoutPill(title: method.label, isSelected: paymentMethod == method, accentColor: accentColor) {
            guard paymentMethod != method else { return }
            paymentMethod = method
            clearRewardQuote()
        }
    }

    @MainActor
    private func searchCustomers(showEmptyMessage: Bool = false) async {
        guard !isSearchingCustomer else { return }
        let query = customerSearch.trimmingCharacters(in: .whitespacesAndNewlines)

        guard query.count >= 2 else {
            customerResults = []
            customerError = nil
            return
        }

        isSearchingCustomer = true
        customerError = nil

        do {
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: posSessionToken).searchPOSCustomers(search: query)
            customerResults = response.customers
            if response.customers.isEmpty && showEmptyMessage {
                customerError = "No customer found."
            }
        } catch {
            customerError = error.localizedDescription
        }

        isSearchingCustomer = false
    }

    private func scheduleCustomerSuggestions(for value: String) {
        customerSearchTask?.cancel()

        if let selectedCustomer, value == selectedCustomer.name {
            return
        }

        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            customerResults = []
            customerError = nil
            return
        }

        customerSearchTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await searchCustomers(showEmptyMessage: false)
        }
    }

    private func attachCustomer(_ customer: POSCustomer) {
        clearRewardQuote()
        customerSearchTask?.cancel()
        selectedCustomer = customer
        customerResults = []
        customerSearch = customer.name
        customerError = nil
        Haptics.selectionChanged()
    }

    private func clearSelectedCustomer() {
        clearRewardQuote()
        customerSearchTask?.cancel()
        selectedCustomer = nil
        customerSearch = ""
        customerResults = []
        customerError = nil
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
            let response = try await KitchenAPIClient(baseURL: baseURL, token: token, posSessionToken: posSessionToken).createPOSCustomer(
                POSCreateCustomerRequest(
                    name: name,
                    phone: newCustomerPhone.trimmingCharacters(in: .whitespacesAndNewlines).emptyAsNil,
                    email: newCustomerEmail.trimmingCharacters(in: .whitespacesAndNewlines).emptyAsNil
                )
            )
            attachCustomer(response.customer)
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

    @MainActor
    private func redeemScannedRewardToken(_ token: String) async {
        guard !isScanningReward else { return }

        isRewardScannerOpen = false
        isScanningReward = true
        rewardRedemptionError = nil

        do {
            try await scanRewardToken(token)
            Haptics.notification(.success)
        } catch {
            rewardRedemptionError = error.localizedDescription
            Haptics.notification(.error)
        }

        isScanningReward = false
    }

    @MainActor
    private func previewRewardTotal(automatic: Bool = false) async {
        guard !isQuotingReward else { return }
        guard activeRewardRedemption != nil else {
            rewardRedemptionError = "Scan a reward QR first."
            return
        }

        let eligibleLines = eligibleRewardLines
        let rewardLineKey: String?
        if eligibleLines.isEmpty {
            rewardRedemptionError = "Add one Daily Go, Daily Classic, or standard coffee."
            return
        } else if eligibleLines.count == 1 {
            rewardLineKey = eligibleLines[0].id
            selectedRewardLineID = rewardLineKey
        } else if let selectedRewardLineID, eligibleLines.contains(where: { $0.id == selectedRewardLineID }) {
            rewardLineKey = selectedRewardLineID
        } else {
            rewardRedemptionError = "Choose which item receives this reward."
            return
        }

        if isMarketplaceOrder && trimmedExternalReference.isEmpty {
            checkoutValidationMessage = "Enter the \(orderSource.label) reference before previewing."
            return
        }

        isQuotingReward = true
        clearRewardQuote()
        rewardRedemptionError = nil

        do {
            _ = try await quoteRewardSale(
                paymentMethod,
                orderSource,
                trimmedExternalReference,
                checkoutCustomerForSubmission,
                parsedDiscountPercent,
                notes,
                rewardLineKey
            )
            if !automatic { Haptics.notification(.success) }
        } catch {
            if !Task.isCancelled && !(error is CancellationError) {
                rewardRedemptionError = error.localizedDescription
                if !automatic { Haptics.notification(.error) }
            }
        }

        isQuotingReward = false
    }
}

private enum POSCartResetAction: Identifiable {
    case clearCart

    var id: String {
        switch self {
        case .clearCart:
            return "clear-cart"
        }
    }

    var title: String {
        switch self {
        case .clearCart:
            return "Clear cart?"
        }
    }

    var message: String {
        switch self {
        case .clearCart:
            return "This removes every item from the current checkout."
        }
    }

    var confirmTitle: String {
        switch self {
        case .clearCart:
            return "CLEAR CART"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .clearCart:
            return .destructive
        }
    }

    var shouldDismiss: Bool {
        switch self {
        case .clearCart:
            return true
        }
    }

    func perform(clearCart: () -> Void, newTicket: () -> Void) {
        switch self {
        case .clearCart:
            clearCart()
        }
    }
}

private struct POSRewardScannerSheet: View {
    let accentColor: Color
    let onToken: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                POSQRCodeScannerView { code in
                    Task {
                        dismiss()
                        await onToken(code)
                    }
                }
                .ignoresSafeArea()

                VStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 44, weight: .semibold))
                    Text("Scan Free Reward QR")
                        .font(GlacialFont.title3(.semibold))
                    Text("Point the camera at the customer’s reward QR.")
                        .font(GlacialFont.caption())
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.52))
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(accentColor)
                }
            }
        }
    }
}

private enum POSRewardQRToken {
    nonisolated static func normalized(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "mfb-reward-v1."
        guard value.hasPrefix(prefix) else { return nil }
        let secret = value.dropFirst(prefix.count)
        guard secret.utf8.count == 48,
              secret.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return value
    }
}

// Capture configuration, start and stop all run on one serial queue.
private final class POSRewardCamera: @unchecked Sendable {
    nonisolated let session = AVCaptureSession()
    nonisolated private let queue = DispatchQueue(label: "vn.com.fitbites.reward-camera")
    nonisolated(unsafe) private var configured = false

    nonisolated func start(delegate: AVCaptureMetadataOutputObjectsDelegate & Sendable, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            if !configured {
                session.beginConfiguration()
                do {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            ?? AVCaptureDevice.default(for: .video) else {
                        throw NSError(domain: "RewardCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera is available on this device."])
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw NSError(domain: "RewardCamera", code: 2, userInfo: [NSLocalizedDescriptionKey: "The camera could not be opened. Please try again."])
                    }
                    session.addInput(input)
                    let output = AVCaptureMetadataOutput()
                    guard session.canAddOutput(output) else {
                        throw NSError(domain: "RewardCamera", code: 3, userInfo: [NSLocalizedDescriptionKey: "QR scanning is unavailable. Please try again."])
                    }
                    session.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else {
                        throw NSError(domain: "RewardCamera", code: 4, userInfo: [NSLocalizedDescriptionKey: "This camera does not support QR scanning."])
                    }
                    output.setMetadataObjectsDelegate(delegate, queue: .main)
                    output.metadataObjectTypes = [.qr]
                    configured = true
                    session.commitConfiguration()
                } catch {
                    session.inputs.forEach { session.removeInput($0) }
                    session.outputs.forEach { session.removeOutput($0) }
                    session.commitConfiguration()
                    completion(error.localizedDescription)
                    return
                }
            }
            if !session.isRunning { session.startRunning() }
            completion(session.isRunning ? nil : "The camera is unavailable. Close other camera apps and try again.")
        }
    }

    nonisolated func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

private struct POSQRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> ScannerViewController { ScannerViewController(coordinator: context.coordinator) }
    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: Coordinator) { uiViewController.stopCamera() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let onCode: (String) -> Void
        private(set) var didCapture = false
        var onInvalidCode: (() -> Void)?
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !didCapture else { return }
            let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            guard !codes.isEmpty else { return }
            guard let token = codes.compactMap(POSRewardQRToken.normalized).first else { onInvalidCode?(); return }
            didCapture = true
            onCode(token)
        }
    }

    final class ScannerViewController: UIViewController {
        private let camera = POSRewardCamera()
        private let coordinator: Coordinator
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var visible = false
        private var starting = false
        private let status = UILabel()
        private let retryButton = UIButton(type: .system)
        private let settingsButton = UIButton(type: .system)
        private let panel = UIStackView()

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let preview = AVCaptureVideoPreviewLayer(session: camera.session)
            preview.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview
            status.textColor = .white
            status.numberOfLines = 0
            status.textAlignment = .center
            retryButton.setTitle("Try again", for: .normal)
            retryButton.addTarget(self, action: #selector(startCamera), for: .touchUpInside)
            settingsButton.setTitle("Open Settings", for: .normal)
            settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
            panel.axis = .vertical
            panel.spacing = 16
            panel.backgroundColor = UIColor.black.withAlphaComponent(0.8)
            panel.layer.cornerRadius = 16
            panel.isLayoutMarginsRelativeArrangement = true
            panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
            [status, retryButton, settingsButton].forEach { panel.addArrangedSubview($0) }
            panel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                panel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -50),
                panel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
                panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                panel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            ])
            coordinator.onInvalidCode = { [weak self] in self?.showStatus("Scan a Fitbites reward QR.", retry: false) }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(startCamera), name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(pauseCamera), name: UIApplication.willResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(cameraInterrupted), name: AVCaptureSession.wasInterruptedNotification, object: camera.session)
            center.addObserver(self, selector: #selector(cameraResumed), name: AVCaptureSession.interruptionEndedNotification, object: camera.session)
            center.addObserver(self, selector: #selector(cameraFailed), name: AVCaptureSession.runtimeErrorNotification, object: camera.session)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
            if let connection = previewLayer?.connection, connection.isVideoOrientationSupported {
                switch view.window?.windowScene?.interfaceOrientation {
                case .landscapeLeft: connection.videoOrientation = .landscapeLeft
                case .landscapeRight: connection.videoOrientation = .landscapeRight
                case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
                default: connection.videoOrientation = .portrait
                }
            }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            visible = true
            startCamera()
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopCamera()
        }
        func stopCamera() { visible = false; camera.stop() }
        @objc private func pauseCamera() { camera.stop() }
        @objc private func cameraInterrupted() { DispatchQueue.main.async { [weak self] in self?.showStatus("Camera interrupted. Scanning resumes when the camera is available.", retry: true) } }
        @objc private func cameraFailed() { DispatchQueue.main.async { [weak self] in self?.showStatus("The camera stopped. Please try again.", retry: true) } }
        @objc private func cameraResumed() { DispatchQueue.main.async { [weak self] in self?.startCamera() } }
        @objc private func openSettings() {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        private func showStatus(_ message: String, retry: Bool, settings: Bool = false) {
            status.text = message
            retryButton.isHidden = !retry
            settingsButton.isHidden = !settings
            panel.isHidden = false
        }
        @objc private func startCamera() {
            guard visible, !starting, !coordinator.didCapture, UIApplication.shared.applicationState == .active else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                starting = true
                showStatus("Allow camera access to scan rewards.", retry: false)
                AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.starting = false
                        self?.startCamera()
                    }
                }
            case .denied, .restricted:
                showStatus("Camera access is off. Enable it in Settings to scan reward QR codes.", retry: false, settings: true)
            case .authorized:
                starting = true
                showStatus("Opening camera…", retry: false)
                camera.start(delegate: coordinator) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.starting = false
                        guard self.visible, UIApplication.shared.applicationState == .active else { self.camera.stop(); return }
                        if let error { self.showStatus(error, retry: true) }
                        else { self.panel.isHidden = true }
                    }
                }
            @unknown default:
                showStatus("Camera access is unavailable.", retry: true)
            }
        }
    }
}

private struct POSCheckoutTopAction: View {
    let title: String
    let tint: Color
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        POSRectActionLabel(
            title: title,
            tint: tint,
            isPrimary: isPrimary,
            minWidth: title.count > 6 ? 108 : 76
        )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

private struct POSRectActionLabel: View {
    let title: String
    let tint: Color
    var isPrimary = true
    var isLoading = false
    var minWidth: CGFloat? = nil
    var fillsWidth = false

    var body: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(isPrimary ? .white : tint)
            }

            Text(title)
                .font(GlacialFont.caption(.bold))
                .tracking(2)
        }
        .foregroundStyle(isPrimary ? .white : tint)
        .frame(minWidth: minWidth)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .padding(.vertical, 13)
        .padding(.horizontal, fillsWidth ? 18 : 14)
        .background(isPrimary ? tint : .white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPrimary ? tint.opacity(0.12) : AppPalette.line.opacity(0.82), lineWidth: 1)
        )
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
                    POSLoyaltyStarsView(customer: customer, accentColor: accentColor)
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

private struct POSLoyaltyStarsView: View {
    let customer: POSCustomer
    let accentColor: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<customer.loyaltyTarget, id: \.self) { index in
                Image(systemName: index < customer.loyaltyStamps ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(index < customer.loyaltyStamps ? accentColor : AppPalette.muted.opacity(0.42))
            }

            if customer.rewardCount > 0 {
                Text("\(customer.rewardCount) reward\(customer.rewardCount == 1 ? "" : "s")")
                    .font(GlacialFont.caption2(.bold))
                    .foregroundStyle(accentColor)
                    .padding(.leading, 4)
            }
        }
        .accessibilityLabel("\(customer.loyaltyStamps) of \(customer.loyaltyTarget) stamps")
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
    let trailing: AnyView?
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = nil
        self.content = content()
    }

    init<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = AnyView(trailing())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.muted)

                Spacer()

                trailing
            }
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
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppPalette.card)

                RoundedRectangle(cornerRadius: 8)
                    .fill(accentColor)
                    .scaleEffect(isSelected ? 1 : 0.82, anchor: .center)
                    .opacity(isSelected ? 1 : 0)

                Text(title.uppercased())
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.1)
                    .foregroundStyle(isSelected ? .white : AppPalette.ink)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .animation(.smooth(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private struct POSCheckoutRecapLine: View {
    let index: Int
    let line: POSCartLine
    let imageURL: URL?
    let accentColor: Color
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let onRemove: () -> Void
    let orderSource: POSOrderSource
    let onMarketplacePriceChange: (Double?) -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var isDeleteRevealed = false
    @State private var isHorizontalSwipeActive = false
    @State private var marketplacePriceText = ""
    @State private var isEditingMarketplacePrice = false
    @FocusState private var isMarketplacePriceFocused: Bool

    private let revealWidth: CGFloat = 84
    private let deleteThreshold: CGFloat = 136

    private var effectiveUnitPrice: Double {
        line.unitPrice(for: orderSource)
    }

    private var effectiveLineTotal: Double {
        line.lineTotal(for: orderSource)
    }

    var body: some View {
        rowContent
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var rowContent: some View {
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

                    Button(action: removeLine) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppPalette.muted)
                            .frame(width: 28, height: 28)
                            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(effectiveLineTotal).formatted()) VND")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                if line.quantity > 1 {
                    Text("\(line.quantity) x \(line.product.name)")
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.ink.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                if !line.toppings.isEmpty {
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

                if orderSource.isMarketplace {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Marketplace unit")
                            .font(GlacialFont.caption(.medium))
                            .foregroundStyle(AppPalette.muted)

                        Spacer(minLength: 12)

                        TextField("\(Int(effectiveUnitPrice).formatted())", text: $marketplacePriceText)
                            .font(GlacialFont.subheadline(.semibold))
                            .foregroundStyle(AppPalette.ink)
                            .foregroundColor(AppPalette.ink)
                            .tint(accentColor)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .submitLabel(.done)
                            .focused($isMarketplacePriceFocused)
                            .frame(width: 92)
                            .padding(.bottom, 2)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(isMarketplacePriceFocused ? accentColor.opacity(0.72) : AppPalette.line.opacity(0.55))
                                    .frame(height: isMarketplacePriceFocused ? 1.2 : 0.7)
                            }
                            .onTapGesture {
                                beginMarketplacePriceEdit()
                            }
                            .onSubmit {
                                commitMarketplacePriceEdit()
                            }
                            .onChange(of: marketplacePriceText) { _, newValue in
                                let formatted = POSMoneyParser.formattedInput(newValue)
                                if formatted != newValue {
                                    marketplacePriceText = formatted
                                    updateMarketplacePriceIfPossible(formatted)
                                } else {
                                    updateMarketplacePriceIfPossible(newValue)
                                }
                            }
                            .onChange(of: isMarketplacePriceFocused) { _, isFocused in
                                if isFocused {
                                    beginMarketplacePriceEdit()
                                } else {
                                    commitMarketplacePriceEdit()
                                }
                            }

                        Text("VND")
                            .font(GlacialFont.caption(.semibold))
                            .foregroundStyle(AppPalette.muted)
                    }
                    .padding(.top, 2)
                    .onAppear {
                        syncMarketplacePriceText()
                    }
                    .onChange(of: line.adjustedUnitPrice) { _, _ in
                        syncMarketplacePriceText()
                    }
                    .onChange(of: orderSource) { _, _ in
                        syncMarketplacePriceText()
                    }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                }

                HStack(spacing: 13) {
                    Button(action: onDecrement) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                    }

                    Text("\(line.quantity)")
                        .font(GlacialFont.caption(.bold))
                        .frame(minWidth: 18)
                        .foregroundStyle(AppPalette.ink)

                    Button(action: onIncrement) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                    }

                    Spacer()
                }
                .foregroundStyle(accentColor)
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 12)
        .background(.white)
        .animation(.smooth(duration: 0.24), value: orderSource.isMarketplace)
    }

    private func settleSwipe(revealed: Bool) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            isDeleteRevealed = revealed
            dragOffset = revealed ? -revealWidth : 0
        }
    }

    private func removeLine() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            isDeleteRevealed = false
            isHorizontalSwipeActive = false
            dragOffset = 0
        }
        Haptics.impact(.medium)
        onRemove()
    }

    private func beginMarketplacePriceEdit() {
        guard !isEditingMarketplacePrice else { return }
        isEditingMarketplacePrice = true
        marketplacePriceText = ""
    }

    private func commitMarketplacePriceEdit() {
        guard isEditingMarketplacePrice else { return }
        isEditingMarketplacePrice = false

        guard let price = POSMoneyParser.value(marketplacePriceText) else {
            syncMarketplacePriceText()
            return
        }

        marketplacePriceText = Int(price).formatted()
        onMarketplacePriceChange(price)
    }

    private func updateMarketplacePriceIfPossible(_ text: String) {
        guard isEditingMarketplacePrice,
              let price = POSMoneyParser.value(text) else {
            return
        }

        onMarketplacePriceChange(price)
    }

    private func syncMarketplacePriceText() {
        guard !isEditingMarketplacePrice else { return }
        marketplacePriceText = Int(effectiveUnitPrice).formatted()
    }
}

private struct OrderCard: View {
    let order: KitchenOrder
    let onlineDetails: KitchenOnlineOrder?
    let onSelect: () -> Void
    let onStatus: (KitchenStatus) -> Void

    var body: some View {
        cardContent
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
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

            KitchenReceiptReprintButton(saleID: order.id)
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

            if let onlineDetails {
                FulfillmentBadge(text: onlineDetails.typeText, icon: onlineDetails.fulfillmentIcon, tint: AppPalette.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

private struct OnlineOrderDetailView: View {
    let order: KitchenOnlineOrder
    let accentColor: Color
    let onAccept: () -> Void
    let onMarkPaid: () -> Void
    let onSendToKitchen: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DetailHeroHeader(
                        eyebrow: order.typeText,
                        title: order.orderNumber,
                        subtitle: order.customerDisplay,
                        icon: order.fulfillmentIcon
                    )

                    OnlineOrderSummary(order: order, accentColor: accentColor)

                    OnlineOrderItemsDetail(items: order.items, accentColor: accentColor)

                    if let notes = order.notes, !notes.isEmpty {
                        DetailNoteCard(title: "Order Notes", text: notes)
                    }

                    if order.status == .submitted {
                        HStack(spacing: 10) {
                            Button(action: onDecline) {
                                Text("Decline")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.plain)
                            .font(GlacialFont.callout(.bold))
                            .foregroundStyle(AppPalette.ink)
                            .background(AppPalette.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                            Button(action: onAccept) {
                                Text("Accept")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.plain)
                            .font(GlacialFont.callout(.bold))
                            .foregroundStyle(.white)
                            .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else if order.status == .accepted {
                        HStack(spacing: 10) {
                            Button(action: onDecline) {
                                Text("Cancel")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.plain)
                            .font(GlacialFont.callout(.bold))
                            .foregroundStyle(AppPalette.red)
                            .background(AppPalette.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                            Button(action: order.canMarkPaid ? onMarkPaid : onSendToKitchen) {
                                Text(order.canMarkPaid ? "Mark Paid" : (order.canSendToKitchen ? "Send to Kitchen" : "Waiting for Payment"))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.plain)
                            .font(GlacialFont.callout(.bold))
                            .foregroundStyle(.white)
                            .background(order.canMarkPaid ? AppPalette.green : (order.canSendToKitchen ? accentColor : AppPalette.muted.opacity(0.45)), in: RoundedRectangle(cornerRadius: 8))
                            .disabled(!order.canMarkPaid && !order.canSendToKitchen)
                        }
                    }
                }
                .padding(18)
            }
            .background(AppPalette.background)
            .navigationTitle("Online Order")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct CompletedKitchenTicketDetailView: View {
    let ticket: CompletedKitchenTicket
    let accentColor: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: ticket.fulfillmentIcon)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(accentColor)
                                .frame(width: 40, height: 40)
                                .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(ticket.typeText.uppercased())
                                    .font(GlacialFont.caption2(.bold))
                                    .tracking(2)
                                    .foregroundStyle(accentColor)

                                Text(ticket.orderNumber)
                                    .font(GlacialFont.title3(.semibold))
                                    .foregroundStyle(AppPalette.ink)
                            }

                            Spacer(minLength: 0)
                        }

                        DetailInfoList(rows: [
                            DetailInfoRow(title: "DATE", value: ticket.completedDateText),
                            DetailInfoRow(title: "TIME", value: ticket.completedTimeText),
                            DetailInfoRow(title: "TYPE", value: ticket.typeText),
                            DetailInfoRow(title: "PAYMENT", value: ticket.paymentText)
                        ])

                        VStack(spacing: 0) {
                            ForEach(Array(ticket.items.enumerated()), id: \.element.id) { index, item in
                                CompletedReceiptItemRow(item: item, accentColor: accentColor)

                                if index < ticket.items.count - 1 {
                                    SettingsDivider()
                                }
                            }
                        }

                        SettingsDivider()

                        HStack {
                            Text("TOTAL")
                                .font(GlacialFont.caption(.bold))
                                .tracking(2)
                                .foregroundStyle(AppPalette.ink)

                            Spacer()

                            Text(ticket.totalText)
                                .font(GlacialFont.title3(.semibold))
                                .foregroundStyle(accentColor)
                        }
                    }
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                    )

                    if let notes = ticket.notes, !notes.isEmpty {
                        DetailNoteCard(title: "Order Notes", text: notes)
                    }
                }
                .padding(18)
            }
            .background(AppPalette.background)
            .navigationTitle("Completed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    KitchenReceiptReprintButton(saleID: ticket.id)
                }
            }
        }
    }
}

private struct CompletedReceiptItemRow: View {
    let item: CompletedKitchenTicketItem
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(item.quantity)x")
                    .font(GlacialFont.caption(.bold))
                    .foregroundStyle(accentColor)
                    .frame(width: 30, alignment: .leading)

                Text(item.productName)
                    .font(GlacialFont.subheadline(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Text(item.priceText)
                    .font(GlacialFont.caption(.bold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if !item.toppingText.isEmpty {
                Text(item.toppingText)
                    .font(GlacialFont.caption(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct OnlineOrderSummary: View {
    let order: KitchenOnlineOrder
    let accentColor: Color

    var body: some View {
        DetailInfoList(rows: [
            DetailInfoRow(title: "TYPE", value: order.typeText),
            DetailInfoRow(title: "NAME", value: order.contactName),
            DetailInfoRow(title: "PHONE", value: order.contactPhone ?? "None"),
            DetailInfoRow(title: order.isDelivery ? "ADDRESS" : "PICKUP", value: order.destinationText),
            DetailInfoRow(title: "VERIFIED", value: order.isDelivery ? (order.deliveryAddressVerified ? "Yes" : "No") : "Not needed"),
            DetailInfoRow(title: "PAYMENT", value: order.paymentSummaryText),
            DetailInfoRow(title: "TOTAL", value: order.totalText)
        ])
    }
}

private struct CompletedTicketSummary: View {
    let ticket: CompletedKitchenTicket
    let accentColor: Color

    var body: some View {
        DetailInfoList(rows: [
            DetailInfoRow(title: "TYPE", value: ticket.typeText),
            DetailInfoRow(title: "NAME", value: ticket.customerName),
            DetailInfoRow(title: "PHONE", value: ticket.customerPhone ?? "None"),
            DetailInfoRow(title: ticket.isDelivery ? "ADDRESS" : "PICKUP", value: ticket.destinationText),
            DetailInfoRow(title: "PAYMENT", value: ticket.paymentText),
            DetailInfoRow(title: "COMPLETED", value: ticket.completedText),
            DetailInfoRow(title: "TOTAL", value: ticket.totalText)
        ])
    }
}

private struct DetailInfoList: View {
    let rows: [DetailInfoRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                DetailInfoLine(row: row)

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(AppPalette.line)
                        .frame(height: 1)
                        .padding(.leading, 14)
                }
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct DetailInfoRow {
    let title: String
    let value: String
}

private struct DetailInfoLine: View {
    let row: DetailInfoRow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(row.title)
                .font(GlacialFont.caption(.bold))
                .tracking(1.8)
                .foregroundStyle(AppPalette.muted)

            Text(row.value)
                .font(GlacialFont.body(.semibold))
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private struct DetailHeroHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow.uppercased())
                    .font(GlacialFont.caption(.bold))
                    .tracking(2.1)
                    .foregroundStyle(AppPalette.muted)
                Text(title)
                    .font(GlacialFont.largeTitle(.semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(subtitle)
                    .font(GlacialFont.title3(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 12)

            Image(systemName: icon)
                .symbolVariant(.fill)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 64, height: 64)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct OnlineOrderItemsDetail: View {
    let items: [KitchenOnlineOrderItem]
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Items")
                .font(GlacialFont.headline())
                .foregroundStyle(AppPalette.ink)

            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(item.quantity)x")
                            .font(GlacialFont.headline())
                            .foregroundStyle(accentColor)
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

                    if let notes = item.notes, !notes.isEmpty {
                        Text(notes)
                            .font(GlacialFont.caption(.medium))
                            .foregroundStyle(AppPalette.muted)
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
    }
}

private struct CompletedTicketItemCard: View {
    let item: CompletedKitchenTicketItem
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(item.quantity)x")
                    .font(GlacialFont.headline())
                    .foregroundStyle(accentColor)
                    .frame(width: 44, alignment: .leading)

                Text(item.productName)
                    .font(GlacialFont.body(.semibold))
                    .foregroundStyle(AppPalette.ink)

                Spacer()
            }

            if !item.toppings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.toppings) { topping in
                        Text("+ \(topping.name) x \(topping.quantity)")
                            .font(GlacialFont.caption(.medium))
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .padding(.leading, 56)
            }

            if let notes = item.notes, !notes.isEmpty {
                Text(notes)
                    .font(GlacialFont.caption(.medium))
                    .foregroundStyle(AppPalette.muted)
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

private struct DetailNoteCard: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(GlacialFont.headline())
                .foregroundStyle(AppPalette.ink)
            Text(text)
                .font(GlacialFont.subheadline(.medium))
                .foregroundStyle(AppPalette.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OrderDetailView: View {
    let order: KitchenOrder
    let onlineDetails: KitchenOnlineOrder?
    let onStatus: (KitchenStatus) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let onlineDetails {
                        DetailHeroHeader(
                            eyebrow: "\(order.status.label) · \(onlineDetails.typeText)",
                            title: order.orderNumber,
                            subtitle: order.customerDisplay,
                            icon: onlineDetails.fulfillmentIcon
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            StatusBadge(status: order.status)
                            Text(order.orderNumber)
                                .font(GlacialFont.largeTitle(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text(order.customerDisplay)
                                .font(GlacialFont.title3(.medium))
                                .foregroundStyle(AppPalette.muted)
                        }
                    }

                    DetailSummary(order: order, onlineDetails: onlineDetails)

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
    let onlineDetails: KitchenOnlineOrder?

    var body: some View {
        DetailInfoList(rows: detailRows)
    }

    private var detailRows: [DetailInfoRow] {
        var rows = [
            DetailInfoRow(title: "TYPE", value: onlineDetails?.typeText ?? order.source.rawValue),
            DetailInfoRow(title: "NAME", value: onlineDetails?.contactName ?? order.customerDisplay),
            DetailInfoRow(title: "PHONE", value: onlineDetails?.contactPhone ?? order.customer.phone ?? "None")
        ]

        if let onlineDetails {
            rows.append(DetailInfoRow(title: onlineDetails.isDelivery ? "ADDRESS" : "PICKUP", value: onlineDetails.destinationText))
            rows.append(DetailInfoRow(title: "PAYMENT", value: onlineDetails.paymentSummaryText))
        } else {
            rows.append(DetailInfoRow(title: "ELAPSED", value: order.elapsedText))
        }

        rows.append(DetailInfoRow(title: "TOTAL", value: order.totalText))
        return rows
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .symbolVariant(.fill)
                .foregroundStyle(AppPalette.ink)
                .frame(width: 30, height: 30)

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
        .background(.white, in: RoundedRectangle(cornerRadius: 4))
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
    var onClose: (() -> Void)?
    let refresh: () -> Void
    @State private var expandedSourceKey: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

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
                        POSRecapSourceSection(
                            emptyText: "No sources yet today.",
                            splits: recap.sourceSplit,
                            expandedSourceKey: $expandedSourceKey,
                            accentColor: accentColor
                        )
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
            .safeAreaInset(edge: .top, spacing: 0) {
                recapTopBar
            }
            .onAppear {
                if recap == nil {
                    refresh()
                }
            }
        }
    }

    private var recapTopBar: some View {
        ZStack {
            Text("RECAP")
                .font(GlacialFont.subheadline(.medium))
                .tracking(2.4)
                .foregroundStyle(AppPalette.ink)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.white)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
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

private struct POSRecapSourceSection: View {
    let emptyText: String
    let splits: [POSRecapSplit]
    @Binding var expandedSourceKey: String?
    let accentColor: Color

    var body: some View {
        POSRecapCard(title: "SOURCE", icon: "point.3.connected.trianglepath.dotted") {
            if splits.isEmpty {
                POSRecapEmptyLine(text: emptyText)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(splits.enumerated()), id: \.element.id) { index, split in
                        POSRecapSourceRow(
                            split: split,
                            isExpanded: expandedSourceKey == split.key,
                            accentColor: accentColor
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                expandedSourceKey = expandedSourceKey == split.key ? nil : split.key
                            }
                        }

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

private struct POSRecapSourceRow: View {
    let split: POSRecapSplit
    let isExpanded: Bool
    let accentColor: Color
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
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

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.muted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 18, height: 18)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    if split.isMarketplaceSource {
                        POSRecapSourceTotals(split: split, accentColor: accentColor)
                        SettingsDivider()
                    }

                    if split.orders.isEmpty {
                        POSRecapEmptyLine(text: "No orders recorded for this source.")
                    } else {
                        ForEach(Array(split.orders.enumerated()), id: \.element.id) { index, order in
                            POSRecapSourceOrderRow(order: order, accentColor: accentColor)

                            if index < split.orders.count - 1 {
                                SettingsDivider()
                            }
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(accentColor.opacity(0.35))
                        .frame(width: 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .padding(.bottom, 8)
            }
        }
    }
}

private struct POSRecapSourceTotals: View {
    let split: POSRecapSplit
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            POSRecapSourceTotalLine(
                title: "TOTAL \(split.marketplaceName.uppercased()) REVENUE",
                value: split.salesTotal.currencyText,
                accentColor: accentColor
            )

            SettingsDivider()

            POSRecapSourceTotalLine(
                title: "REVENUE",
                value: split.receivedTotal.currencyText,
                accentColor: accentColor
            )
        }
        .padding(.vertical, 5)
    }
}

private struct POSRecapSourceTotalLine: View {
    let title: String
    let value: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(GlacialFont.caption2(.bold))
                .tracking(1.7)
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer()

            Text(value)
                .font(GlacialFont.caption(.bold))
                .tracking(0.7)
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 8)
    }
}

private struct POSRecapSourceOrderRow: View {
    let order: POSRecapOrder
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.reference.uppercased())
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.3)
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)

                if let time = order.time, !time.isEmpty {
                    Text(time)
                        .font(GlacialFont.caption2())
                        .tracking(0.8)
                        .foregroundStyle(AppPalette.muted)
                }
            }

            Spacer()

            Text(order.amount.currencyText)
                .font(GlacialFont.caption(.bold))
                .tracking(0.7)
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 8)
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
    @ObservedObject var printStore: PrintBridgeStore
    var isConnectionOnly = false
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("POSProductDisplayStyle") private var posProductDisplayStyleRaw = POSProductDisplayStyle.productCard.rawValue
    @AppStorage("POSAccentColor") private var posAccentColorRaw = POSAccentColor.ember.rawValue
    @AppStorage("POSToppingCategoryOrder") private var posToppingCategoryOrderRaw = ""
    @AppStorage("POSBrandLogoHidden") private var posBrandLogoHidden = false
    @AppStorage("POSBrandLogoScale") private var posBrandLogoScale = 1.0
    @AppStorage("StudioToken") private var savedStudioToken = ""
    @State private var baseURL: String = ""
    @State private var token: String = ""
    @State private var studioToken: String = ""
    @State private var printServerURL: String = ""
    @State private var printToken: String = ""
    @State private var printerHost: String = ""
    @State private var printerPort: String = "9100"
    @State private var printerPaperWidth: String = "80"
    @State private var autoPrint = false
    @State private var printStoreSource = true
    @State private var printWebsiteSource = true
    @State private var printGrabSource = false
    @State private var printShopeeSource = false
    @State private var previewTone: KitchenChimeTone?
    @State private var connectionOpen = false
    @State private var printOpen = false
    @State private var soundOpen = false
    @State private var displayOpen = false
    @State private var catalogOpen = false

    private var selectedPOSDisplayStyle: POSProductDisplayStyle {
        POSProductDisplayStyle(rawValue: posProductDisplayStyleRaw) ?? .productCard
    }

    private var selectedPOSAccentColor: POSAccentColor {
        POSAccentColor(rawValue: posAccentColorRaw) ?? .ember
    }

    private var toppingCategories: [String] {
        let source = Set(
            (posStore.bootstrap?.catalog.products ?? [])
                .flatMap(\.toppings)
                .map(\.category)
                .filter { !$0.isEmpty }
        )

        let saved = posToppingCategoryOrderRaw.csvValues.filter { source.contains($0) }
        let missing = source.filter { !saved.contains($0) }.sorted()
        return saved + missing
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
                            SettingsDivider()
                            SettingsTextFieldRow(title: "Studio Key", text: $studioToken, isSecure: true)
                        }
                    }

                    if !isConnectionOnly {
                        fullSettingsSections
                    }

                    Button {
                        store.saveSettings(baseURL: baseURL, token: token)
                        savedStudioToken = studioToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        savePrintSettings()
                        close()
                    } label: {
                        POSRectActionLabel(
                            title: "SAVE",
                            tint: selectedPOSAccentColor.color,
                            isPrimary: true,
                            fillsWidth: true
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(18)
            }
            .background(Color.white.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                settingsTopBar
            }
            .onAppear {
                baseURL = store.baseURL
                token = store.kitchenToken
                studioToken = savedStudioToken
                connectionOpen = isConnectionOnly || connectionOpen
                printServerURL = printStore.serverURL
                printToken = printStore.printToken
                printerHost = printStore.printerHost
                printerPort = "\(printStore.printerPort)"
                printerPaperWidth = "\(printStore.paperWidth)"
                autoPrint = printStore.autoPrint
                printStoreSource = printStore.enabledSources.store
                printWebsiteSource = printStore.enabledSources.website
                printGrabSource = printStore.enabledSources.grab
                printShopeeSource = printStore.enabledSources.shopee
            }
        }
    }

    @ViewBuilder
    private var fullSettingsSections: some View {
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
            title: "Print",
            subtitle: printStore.autoPrint ? "Auto-print on · \(printStore.printerHost)" : "Auto-print off · \(printStore.printerHost)",
            icon: "printer",
            isExpanded: $printOpen,
            accentColor: selectedPOSAccentColor.color
        ) {
            VStack(spacing: 0) {
                SettingsTextFieldRow(title: "Server URL", text: $printServerURL, isSecure: false)
                SettingsDivider()
                SettingsTextFieldRow(title: "Print Key", text: $printToken, isSecure: true)
                SettingsDivider()
                SettingsTextFieldRow(title: "Printer IP", text: $printerHost, isSecure: false)
                SettingsDivider()

                HStack(spacing: 12) {
                    SettingsCompactTextField(title: "Port", text: $printerPort, keyboard: .numberPad)
                    SettingsCompactTextField(title: "Paper", text: $printerPaperWidth, keyboard: .numberPad)
                }
                .padding(.vertical, 12)

                SettingsDivider()

                Toggle(isOn: $autoPrint) {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.badge.automatic")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(selectedPOSAccentColor.color)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Auto-print")
                                .font(GlacialFont.body(.semibold))
                                .foregroundStyle(AppPalette.ink)

                            Text("Print receipt jobs when this iPad is open.")
                                .font(GlacialFont.caption())
                                .foregroundStyle(AppPalette.muted)
                        }
                    }
                }
                .tint(selectedPOSAccentColor.color)
                .padding(.vertical, 12)

                SettingsDivider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("PRINT SOURCES")
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.muted)

                    VStack(spacing: 0) {
                        PrintSourceToggleRow(title: "STORE", subtitle: "Native POS and counter sales", isOn: $printStoreSource, accentColor: selectedPOSAccentColor.color)
                        SettingsDivider()
                        PrintSourceToggleRow(title: "WEBSITE", subtitle: "Online pickup and delivery", isOn: $printWebsiteSource, accentColor: selectedPOSAccentColor.color)
                        SettingsDivider()
                        PrintSourceToggleRow(title: "GRAB", subtitle: "Marketplace orders", isOn: $printGrabSource, accentColor: selectedPOSAccentColor.color)
                        SettingsDivider()
                        PrintSourceToggleRow(title: "SHOPEE", subtitle: "Marketplace orders", isOn: $printShopeeSource, accentColor: selectedPOSAccentColor.color)
                    }
                }
                .padding(.vertical, 12)

                SettingsDivider()

                HStack(spacing: 12) {
                    Image(systemName: printStore.isConnected ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(printStore.isConnected ? AppPalette.green : AppPalette.red)

                    Text(printStore.statusMessage)
                        .font(GlacialFont.caption(.semibold))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(2)

                    Spacer()
                }
                .padding(.vertical, 12)

                Button {
                    savePrintSettings()
                    Task { await printStore.printTestReceipt() }
                } label: {
                    HStack(spacing: 10) {
                        if printStore.isPrinting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "printer.filled.and.paper")
                        }

                        Text("TEST PRINT")
                            .tracking(1.8)
                    }
                    .font(GlacialFont.caption(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(selectedPOSAccentColor.color, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(printStore.isPrinting)
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
                POSBrandLogoSettingsCard(
                    logoURL: posStore.brandLogoOverrideURL,
                    isHidden: $posBrandLogoHidden,
                    scale: $posBrandLogoScale,
                    accentColor: selectedPOSAccentColor.color
                ) { data in
                    await posStore.setBrandLogoOverride(data: data)
                } onReset: {
                    posStore.clearBrandLogoOverride()
                    posBrandLogoHidden = false
                    posBrandLogoScale = 1.35
                }

                SettingsDivider()
                    .padding(.vertical, 4)

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
                POSToppingCategoryOrderSettings(
                    categories: toppingCategories,
                    accentColor: selectedPOSAccentColor.color
                ) { category, offset in
                    moveToppingCategory(category, offset: offset)
                }
                SettingsDivider()
                LockedCatalogSettingsCard(accentColor: selectedPOSAccentColor.color)
            }
        }
    }

    private var settingsTopBar: some View {
        ZStack {
            Text("SETTINGS")
                .font(GlacialFont.subheadline(.medium))
                .tracking(2.4)
                .foregroundStyle(AppPalette.ink)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.white)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func savePrintSettings() {
        printStore.saveSettings(
            serverURL: printServerURL,
            token: printToken,
            host: printerHost,
            port: Int(printerPort) ?? 9100,
            paperWidth: Int(printerPaperWidth) ?? 80,
            autoPrint: autoPrint,
            enabledSources: PrintSourceSelection(
                store: printStoreSource,
                website: printWebsiteSource,
                grab: printGrabSource,
                shopee: printShopeeSource
            )
        )
    }

    private func moveToppingCategory(_ category: String, offset: Int) {
        var categories = toppingCategories
        guard let index = categories.firstIndex(of: category) else { return }

        let destination = index + offset
        guard categories.indices.contains(destination) else { return }

        categories.swapAt(index, destination)
        posToppingCategoryOrderRaw = categories.csvStorageValue
        Haptics.impact(.light)
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

private struct SettingsCompactTextField: View {
    let title: String
    @Binding var text: String
    let keyboard: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(GlacialFont.caption(.bold))
                .tracking(1.4)
                .foregroundStyle(AppPalette.muted)

            TextField(title, text: $text)
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(AppPalette.ink)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PrintSourceToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let accentColor: Color

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 30, height: 30)
                    .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(GlacialFont.subheadline(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(AppPalette.ink)

                    Text(subtitle)
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                }
            }
        }
        .tint(accentColor)
        .padding(.vertical, 11)
    }

    private var icon: String {
        switch title {
        case "STORE":
            return "cart"
        case "WEBSITE":
            return "globe"
        case "GRAB":
            return "bag"
        case "SHOPEE":
            return "shippingbox"
        default:
            return "printer"
        }
    }
}

private struct POSBrandLogoSettingsCard: View {
    let logoURL: URL?
    @Binding var isHidden: Bool
    @Binding var scale: Double
    let accentColor: Color
    let onPicked: (Data) async -> Void
    let onReset: () -> Void
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                logoPreview

                VStack(alignment: .leading, spacing: 4) {
                    Text("BRAND LOGO")
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.muted)
                    Text(logoURL == nil ? "emberOS default" : "custom logo")
                        .font(GlacialFont.subheadline(.semibold))
                        .foregroundStyle(AppPalette.ink)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { !isHidden },
                    set: { isHidden = !$0 }
                ))
                .labelsHidden()
                .tint(accentColor)
            }
            .padding(.vertical, 12)

            SettingsDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("LOGO SIZE")
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.muted)

                    Spacer()

                    Text("\(Int((scale * 100).rounded()))%")
                        .font(GlacialFont.caption(.semibold))
                        .foregroundStyle(AppPalette.ink)
                        .monospacedDigit()
                }

                Slider(value: $scale, in: 0.6...1.8, step: 0.05)
                    .tint(accentColor)
                    .disabled(isHidden)
            }
            .padding(.vertical, 12)

            SettingsDivider()

            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    POSRectActionLabel(
                        title: logoURL == nil ? "CHOOSE LOGO" : "CHANGE LOGO",
                        tint: accentColor,
                        isPrimary: true,
                        minWidth: 132
                    )
                }
                .buttonStyle(.plain)

                if logoURL != nil || isHidden {
                    Button {
                        onReset()
                    } label: {
                        POSRectActionLabel(
                            title: "RESET",
                            tint: AppPalette.ink,
                            isPrimary: false,
                            minWidth: 84
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.vertical, 12)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await onPicked(data)
                    isHidden = false
                    scale = max(scale, 1.35)
                }
                selectedPhoto = nil
            }
        }
    }

    private var logoPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppPalette.card)
                .frame(width: 86, height: 52)

            if isHidden {
                Image(systemName: "eye.slash")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppPalette.muted)
            } else if let logoURL, logoURL.isFileURL, let image = UIImage(contentsOfFile: logoURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(7)
            } else {
                Image("EmberOSLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(7)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppPalette.line.opacity(0.76), lineWidth: 1)
        )
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.line.opacity(0.66))
            .frame(height: 1)
    }
}

private struct POSToppingCategoryOrderSettings: View {
    let categories: [String]
    let accentColor: Color
    let onMove: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 34, height: 34)
                    .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Topping order")
                        .font(GlacialFont.body(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text("Arrange topping categories in the product drawer.")
                        .font(GlacialFont.caption())
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer()
            }

            if categories.isEmpty {
                Text("No topping categories found yet.")
                    .font(GlacialFont.subheadline())
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(GlacialFont.caption(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(accentColor, in: RoundedRectangle(cornerRadius: 7))

                            Text(category.uppercased())
                                .font(GlacialFont.subheadline(.semibold))
                                .tracking(1.2)
                                .foregroundStyle(AppPalette.ink)
                                .lineLimit(1)

                            Spacer()

                            HStack(spacing: 6) {
                                toppingOrderButton(systemName: "chevron.up", disabled: index == 0) {
                                    onMove(category, -1)
                                }

                                toppingOrderButton(systemName: "chevron.down", disabled: index == categories.count - 1) {
                                    onMove(category, 1)
                                }
                            }
                        }
                        .padding(.vertical, 10)

                        if index < categories.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(AppPalette.card.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func toppingOrderButton(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .foregroundStyle(disabled ? AppPalette.muted.opacity(0.45) : accentColor)
                .frame(width: 30, height: 30)
                .background(.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(AppPalette.line.opacity(0.72), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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

struct KitchenSendOnlineOrderToKitchenResponse: Decodable {
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

struct POSPinSessionRequest: Encodable {
    let pin: String
    let openingCash: Double?
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case pin
        case openingCash = "opening_cash"
        case deviceName = "device_name"
    }
}

struct POSPinSessionResponse: Codable, Equatable {
    let message: String
    let `operator`: POSOperator
    let sessionToken: String
    let shift: POSShiftEnvelope
    let openingCash: Double

    enum CodingKeys: String, CodingKey {
        case message
        case `operator`
        case sessionToken = "session_token"
        case shift
        case openingCash = "opening_cash"
    }
}

private struct POSPinWelcome: Equatable {
    let operatorName: String
    let openingCash: Double
}

struct POSBootstrapResponse: Codable, Equatable {
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
    let receivedTotal: Double
    let orders: [POSRecapOrder]

    var id: String { key }

    var isMarketplaceSource: Bool {
        key == "grabfood" || key == "shopeefood"
    }

    var marketplaceName: String {
        key == "shopeefood" ? "Shopee" : "Grab"
    }

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case ordersCount = "orders_count"
        case salesTotal = "sales_total"
        case receivedTotal = "received_total"
        case orders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        label = try container.decode(String.self, forKey: .label)
        ordersCount = try container.decode(Int.self, forKey: .ordersCount)
        salesTotal = container.lossyDouble(forKey: .salesTotal) ?? 0
        receivedTotal = container.lossyDouble(forKey: .receivedTotal) ?? salesTotal
        orders = try container.decodeIfPresent([POSRecapOrder].self, forKey: .orders) ?? []
    }
}

struct POSRecapOrder: Identifiable, Decodable, Equatable {
    let id: Int
    let reference: String
    let amount: Double
    let time: String?
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

struct POSOperator: Codable, Equatable {
    let id: Int
    let name: String
    let role: String

    var normalizedRole: String {
        role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var canAccessAdminFeatures: Bool {
        normalizedRole == "admin" || normalizedRole == "administrator" || normalizedRole == "owner"
    }

    var roleLabel: String {
        canAccessAdminFeatures ? "ADMIN" : "STAFF"
    }
}

struct POSCatalog: Codable, Equatable {
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

    static let empty = POSCatalog(categories: [], products: [], paymentMethods: [], orderSources: [])
}

struct POSCategory: Identifiable, Codable, Equatable {
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

struct POSProduct: Identifiable, Codable, Equatable {
    let id: Int
    let name: String
    let sku: String?
    let price: Double
    let currentStock: Double
    let unit: String
    let category: String
    let inventoryCategory: String?
    let freeRewardEligibility: String?
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
        case freeRewardEligibility = "free_reward_eligibility"
        case sortOrder = "sort_order"
        case description
        case imageURLString = "image_url"
        case toppings
    }
}

struct POSTopping: Identifiable, Codable, Equatable {
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

struct POSDraftTicket: Identifiable, Codable, Equatable {
    let id: UUID
    let number: Int
    var lines: [POSCartLine]

    init(id: UUID = UUID(), number: Int, lines: [POSCartLine] = []) {
        self.id = id
        self.number = number
        self.lines = lines
    }

    var title: String {
        "TICKET \(number)"
    }

    var itemCount: Int {
        lines.reduce(0) { $0 + $1.quantity }
    }

    var total: Double {
        lines.reduce(0) { $0 + $1.lineTotal }
    }
}

struct POSCartLine: Identifiable, Codable, Equatable {
    let id: String
    let product: POSProduct
    let toppings: [POSTopping]
    var quantity: Int
    var adjustedUnitPrice: Double?

    var unitPrice: Double {
        product.price + toppings.reduce(0) { $0 + $1.price }
    }

    var lineTotal: Double {
        unitPrice * Double(quantity)
    }

    func unitPrice(for source: POSOrderSource) -> Double {
        source.isMarketplace ? (adjustedUnitPrice ?? unitPrice) : unitPrice
    }

    func lineTotal(for source: POSOrderSource) -> Double {
        unitPrice(for: source) * Double(quantity)
    }

    init(product: POSProduct, toppings: [POSTopping], quantity: Int, adjustedUnitPrice: Double? = nil) {
        self.id = Self.makeID(product: product, toppings: toppings)
        self.product = product
        self.toppings = toppings.sorted {
            $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder
        }
        self.quantity = quantity
        self.adjustedUnitPrice = adjustedUnitPrice
    }

    static func makeID(product: POSProduct, toppings: [POSTopping]) -> String {
        let toppingKey = toppings.map(\.id).sorted().map(String.init).joined(separator: "-")
        return "\(product.id)|\(toppingKey)"
    }
}

private struct POSDraftTicketSnapshot: Codable {
    let tickets: [POSDraftTicket]
    let activeTicketID: UUID
    let nextTicketNumber: Int
}

private enum POSDraftTicketStore {
    private static let key = "POSDraftTicketSnapshot"

    static func load() -> POSDraftTicketSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder.kitchen.decode(POSDraftTicketSnapshot.self, from: data)
    }

    static func save(tickets: [POSDraftTicket], activeTicketID: UUID, nextTicketNumber: Int) {
        let snapshot = POSDraftTicketSnapshot(
            tickets: tickets,
            activeTicketID: activeTicketID,
            nextTicketNumber: nextTicketNumber
        )
        guard let data = try? JSONEncoder.kitchen.encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
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

    var receiptSourceKey: String {
        switch self {
        case .inStore:
            return "pos"
        case .grabfood:
            return "grabfood"
        case .shopeefood:
            return "shopeefood"
        }
    }

    var isMarketplace: Bool {
        self == .grabfood || self == .shopeefood
    }
}

private enum POSMarketplaceFees {
    static let deductionRate = 0.29037520

    static func deductionAmount(_ grossTotal: Double) -> Double {
        grossTotal * deductionRate
    }

    static func actualReceived(_ grossTotal: Double) -> Double {
        max(0, grossTotal - deductionAmount(grossTotal))
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

struct POSCreateSaleRequest: Codable {
    let cart: [POSSaleCartItem]
    let paymentMethod: String
    let orderSource: String
    let externalOrderReference: String?
    let customerID: Int?
    let discountPercent: Double
    let notes: String?
    let rewardRedemptionSessionID: String?
    let rewardQuoteID: String?
    let rewardLineKey: String?
    let checkoutToken: String

    enum CodingKeys: String, CodingKey {
        case cart
        case paymentMethod = "payment_method"
        case orderSource = "order_source"
        case externalOrderReference = "external_order_reference"
        case customerID = "customer_id"
        case discountPercent = "discount_percent"
        case notes
        case rewardRedemptionSessionID = "reward_redemption_session_id"
        case rewardQuoteID = "reward_quote_id"
        case rewardLineKey = "reward_line_key"
        case checkoutToken = "checkout_token"
    }
}

struct POSRewardScanRequest: Codable {
    let token: String
}

struct POSRewardQuoteRequest: Codable {
    let cart: [POSSaleCartItem]
    let paymentMethod: String
    let orderSource: String
    let externalOrderReference: String?
    let customerID: Int?
    let discountPercent: Double
    let notes: String?
    let rewardRedemptionSessionID: String
    let rewardLineKey: String?
    let checkoutToken: String

    enum CodingKeys: String, CodingKey {
        case cart
        case paymentMethod = "payment_method"
        case orderSource = "order_source"
        case externalOrderReference = "external_order_reference"
        case customerID = "customer_id"
        case discountPercent = "discount_percent"
        case notes
        case rewardRedemptionSessionID = "reward_redemption_session_id"
        case rewardLineKey = "reward_line_key"
        case checkoutToken = "checkout_token"
    }
}

struct POSRewardQuoteResponse: Decodable {
    let rewardQuote: POSRewardQuote

    enum CodingKeys: String, CodingKey {
        case rewardQuote = "reward_quote"
    }
}

struct POSRewardQuote: Identifiable, Decodable, Equatable {
    let id: String
    let expiresAt: String?
    let eligibleProduct: EligibleProduct?
    let subtotal: Double
    let rewardDiscount: Double
    let manualDiscount: Double
    let paidAddOns: Double
    let finalPayableTotal: Double

    struct EligibleProduct: Decodable, Equatable {
        let id: Int
        let name: String
        let lineKey: String?
        let eligibility: String?
        let baseUnitPrice: Double
        let unitPrice: Double

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case lineKey = "line_key"
            case eligibility
            case baseUnitPrice = "base_unit_price"
            case unitPrice = "unit_price"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case expiresAt = "expires_at"
        case eligibleProduct = "eligible_product"
        case subtotal
        case rewardDiscount = "reward_discount"
        case manualDiscount = "manual_discount"
        case paidAddOns = "paid_add_ons"
        case finalPayableTotal = "final_payable_total"
    }
}

struct POSRewardScanResponse: Decodable {
    let session: Session
    let reward: Reward
    let customer: Customer?
    let policy: Policy?

    struct Session: Decodable {
        let id: String
        let status: String
        let reservationExpiresAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case reservationExpiresAt = "reservation_expires_at"
        }
    }

    struct Reward: Decodable {
        let id: String?
        let name: String?
        let status: String?
    }

    struct Customer: Decodable {
        let id: Int?
        let name: String?
        let phone: String?
    }

    struct Policy: Decodable {
        let description: String?
    }
}

struct POSRewardRedemption: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let status: String
    let reservationExpiresAt: String?
    let rewardName: String
    let customerID: Int?
    let customerName: String?
    let customerPhone: String?
    let policyDescription: String?

    init(response: POSRewardScanResponse) {
        self.id = response.session.id
        self.sessionID = response.session.id
        self.status = response.session.status
        self.reservationExpiresAt = response.session.reservationExpiresAt
        self.rewardName = response.reward.name ?? "Free Reward"
        self.customerID = response.customer?.id
        self.customerName = response.customer?.name
        self.customerPhone = response.customer?.phone
        self.policyDescription = response.policy?.description
    }
}

struct POSSaleCartItem: Codable {
    let id: Int
    let lineKey: String
    let quantity: Int
    let toppings: [POSSaleTopping]
    let adjustedUnitPrice: Double?

    init(line: POSCartLine) {
        self.id = line.product.id
        self.lineKey = line.id
        self.quantity = line.quantity
        self.toppings = line.toppings.map { POSSaleTopping(id: $0.id) }
        self.adjustedUnitPrice = line.adjustedUnitPrice
    }

    enum CodingKeys: String, CodingKey {
        case id
        case lineKey = "line_key"
        case quantity
        case toppings
        case adjustedUnitPrice = "adjusted_unit_price"
    }
}

struct POSSaleTopping: Codable {
    let id: Int
}

struct POSCreateSaleResponse: Decodable {
    let message: String
    let saleID: Int
    let alreadyProcessed: Bool
    let total: Double?
    let discount: Double?

    enum CodingKeys: String, CodingKey {
        case message
        case saleID = "sale_id"
        case alreadyProcessed = "already_processed"
        case total
        case discount
    }
}

fileprivate struct POSQueuedSale: Codable, Identifiable {
    let id: UUID
    let request: POSCreateSaleRequest
    let createdAt: Date
    let completionTotal: Double
    let shouldPrintReceipt: Bool

    init(
        id: UUID = UUID(),
        request: POSCreateSaleRequest,
        createdAt: Date,
        completionTotal: Double,
        shouldPrintReceipt: Bool
    ) {
        self.id = id
        self.request = request
        self.createdAt = createdAt
        self.completionTotal = completionTotal
        self.shouldPrintReceipt = shouldPrintReceipt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case request
        case createdAt
        case completionTotal
        case shouldPrintReceipt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        request = try container.decode(POSCreateSaleRequest.self, forKey: .request)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completionTotal = try container.decodeIfPresent(Double.self, forKey: .completionTotal) ?? 0
        shouldPrintReceipt = try container.decodeIfPresent(Bool.self, forKey: .shouldPrintReceipt) ?? true
    }
}

private enum POSQueuedSaleStore {
    private static let key = "POSQueuedSales"

    static func load() -> [POSQueuedSale] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let queue = try? JSONDecoder.kitchen.decode([POSQueuedSale].self, from: data) else {
            return []
        }

        return queue
    }

    static func save(_ queue: [POSQueuedSale]) {
        guard let data = try? JSONEncoder.kitchen.encode(queue) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct POSFailedQueuedSale: Codable, Identifiable {
    let id: UUID
    let sale: POSQueuedSale
    let failedAt: Date
    let reason: String
}

private enum POSFailedQueuedSaleStore {
    private static let key = "POSFailedQueuedSales"

    static func load() -> [POSFailedQueuedSale] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let queue = try? JSONDecoder.kitchen.decode([POSFailedQueuedSale].self, from: data) else {
            return []
        }

        return queue
    }

    static func append(_ sale: POSQueuedSale, reason: String) {
        var failed = load()
        failed.append(POSFailedQueuedSale(id: UUID(), sale: sale, failedAt: Date(), reason: reason))
        guard let data = try? JSONEncoder.kitchen.encode(failed) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct POSQueuedShiftMutation: Codable, Identifiable {
    enum Kind: String, Codable {
        case start
        case cashMovement
        case end
    }

    let id: UUID
    let kind: Kind
    let createdAt: Date
    let startRequest: POSStartShiftRequest?
    let cashMovementRequest: POSCashMovementRequest?
    let endRequest: POSEndShiftRequest?

    static func start(_ request: POSStartShiftRequest) -> POSQueuedShiftMutation {
        POSQueuedShiftMutation(
            id: UUID(),
            kind: .start,
            createdAt: Date(),
            startRequest: request,
            cashMovementRequest: nil,
            endRequest: nil
        )
    }

    static func cashMovement(_ request: POSCashMovementRequest) -> POSQueuedShiftMutation {
        POSQueuedShiftMutation(
            id: UUID(),
            kind: .cashMovement,
            createdAt: Date(),
            startRequest: nil,
            cashMovementRequest: request,
            endRequest: nil
        )
    }

    static func end(_ request: POSEndShiftRequest) -> POSQueuedShiftMutation {
        POSQueuedShiftMutation(
            id: UUID(),
            kind: .end,
            createdAt: Date(),
            startRequest: nil,
            cashMovementRequest: nil,
            endRequest: request
        )
    }
}

private enum POSQueuedShiftMutationStore {
    private static let key = "POSQueuedShiftMutations"

    static func load() -> [POSQueuedShiftMutation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let queue = try? JSONDecoder.kitchen.decode([POSQueuedShiftMutation].self, from: data) else {
            return []
        }

        return queue
    }

    static func save(_ queue: [POSQueuedShiftMutation]) {
        guard let data = try? JSONEncoder.kitchen.encode(queue) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct PrintJobsResponse: Decodable {
    let jobs: [PrintJob]
}

struct PrintJobResponse: Decodable {
    let job: PrintJob
}

struct PrintJobLookupResponse: Decodable {
    let job: PrintJob?
}

struct PrintClaimRequest: Encodable {
    let claimedBy: String

    enum CodingKeys: String, CodingKey {
        case claimedBy = "claimed_by"
    }
}

struct PrintJob: Identifiable, Decodable {
    let id: Int
    let saleID: Int?
    let status: String
    let payload: PrintReceiptPayload
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case saleID = "sale_id"
        case status
        case payload
        case createdAt = "created_at"
    }
}

struct PrintReceiptCopyResponse: Decodable {
    let payload: PrintReceiptPayload
}

struct PrintReceiptPayload: Decodable {
    let store: PrintReceiptStore
    let receipt: PrintReceiptInfo
    let customer: PrintReceiptCustomer?
    let items: [PrintReceiptItem]
    let totals: PrintReceiptTotals
    let notes: String?
    let loyalty: PrintReceiptLoyalty?
}

struct PrintReceiptStore: Decodable {
    let name: String
    let address: String
}

struct PrintReceiptInfo: Decodable {
    let number: String
    let saleID: Int?
    let date: String?
    let cashier: String?
    let paymentMethod: String
    let orderSource: String?

    enum CodingKeys: String, CodingKey {
        case number
        case saleID = "sale_id"
        case date
        case cashier
        case paymentMethod = "payment_method"
        case orderSource = "order_source"
    }
}

struct PrintReceiptCustomer: Decodable {
    let id: Int?
    let name: String?
    let phone: String?
}

struct PrintReceiptLoyalty: Decodable {
    let level: Int
    let xp: Int
    let stamps: Int
    let target: Int
    let rewardCount: Int

    var safeTarget: Int {
        max(1, min(target, 12))
    }

    var safeStamps: Int {
        max(0, min(stamps, safeTarget))
    }

    var receiptStarsLine: String {
        let filled = String(repeating: "*", count: safeStamps)
        let empty = String(repeating: ".", count: safeTarget - safeStamps)
        return "[\(filled)\(empty)] \(safeStamps)/\(safeTarget)"
    }

    enum CodingKeys: String, CodingKey {
        case level
        case xp
        case stamps
        case target
        case rewardCount = "reward_count"
    }

    init(level: Int, xp: Int, stamps: Int, target: Int, rewardCount: Int) {
        self.level = max(1, level)
        self.xp = max(0, xp)
        self.stamps = max(0, stamps)
        self.target = max(1, target)
        self.rewardCount = max(0, rewardCount)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            level: container.lossyInt(forKey: .level) ?? 1,
            xp: container.lossyInt(forKey: .xp) ?? 0,
            stamps: container.lossyInt(forKey: .stamps) ?? 0,
            target: container.lossyInt(forKey: .target) ?? 9,
            rewardCount: container.lossyInt(forKey: .rewardCount) ?? 0
        )
    }
}

private extension KeyedDecodingContainer {
    func lossyInt(forKey key: Key) -> Int? {
        if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
            return intValue
        }

        if let doubleValue = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(doubleValue)
        }

        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    func lossyDouble(forKey key: Key) -> Double? {
        if let doubleValue = try? decodeIfPresent(Double.self, forKey: key) {
            return doubleValue
        }

        if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(intValue)
        }

        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
}

struct PrintReceiptItem: Decodable {
    let name: String
    let sku: String?
    let category: String?
    let quantity: Int
    let baseUnitPrice: Double
    let unitPrice: Double
    let lineTotal: Double
    let toppings: [PrintReceiptTopping]

    var baseLineTotal: Double {
        let toppingTotal = toppings.reduce(0) { $0 + $1.lineTotal }
        let inferredBaseTotal = lineTotal - toppingTotal
        if inferredBaseTotal >= 0, toppingTotal > 0 {
            return inferredBaseTotal
        }

        let baseSubtotal = baseUnitPrice * Double(quantity)
        return baseSubtotal > 0 ? baseSubtotal : lineTotal
    }

    enum CodingKeys: String, CodingKey {
        case name
        case sku
        case category
        case quantity
        case baseUnitPrice = "base_unit_price"
        case unitPrice = "unit_price"
        case lineTotal = "line_total"
        case toppings
    }
}

struct PrintReceiptTopping: Decodable {
    let name: String
    let sku: String?
    let category: String?
    let quantity: Int
    let unitPrice: Double
    let lineTotal: Double

    enum CodingKeys: String, CodingKey {
        case name
        case sku
        case category
        case quantity
        case unitPrice = "unit_price"
        case lineTotal = "line_total"
    }
}

struct PrintReceiptTotals: Decodable {
    let subtotal: Double
    let discount: Double
    let discountPercent: Double
    let deliveryFee: Double
    let total: Double

    enum CodingKeys: String, CodingKey {
        case subtotal
        case discount
        case discountPercent = "discount_percent"
        case deliveryFee = "delivery_fee"
        case total
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

struct POSStartShiftRequest: Codable {
    let openingCash: Double
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case openingCash = "opening_cash"
        case notes
    }
}

struct POSCashMovementRequest: Codable {
    let type: String
    let amount: Double
    let reason: String
}

struct POSEndShiftRequest: Codable {
    let closingCash: Double?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case closingCash = "closing_cash"
        case notes
    }
}

struct POSShiftResponse: Codable {
    let shift: POSShiftEnvelope
}

struct POSShiftEnvelope: Codable, Equatable {
    let isOpen: Bool
    let shift: POSShift?
    let recap: POSShiftRecap?
    let activeOperator: POSOperator?

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open"
        case shift
        case recap
        case activeOperator = "active_operator"
    }

    init(isOpen: Bool, shift: POSShift?, recap: POSShiftRecap?, activeOperator: POSOperator? = nil) {
        self.isOpen = isOpen
        self.shift = shift
        self.recap = recap
        self.activeOperator = activeOperator
    }

    static let offline = POSShiftEnvelope(isOpen: false, shift: nil, recap: nil, activeOperator: nil)
}

struct POSShift: Codable, Equatable {
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

struct POSShiftRecap: Codable, Equatable {
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
    let deliveryRecipientName: String?
    let deliveryPhone: String?
    let deliveryAddress: String?
    let deliveryAddressVerified: Bool
    let pickupTime: String?
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
        case deliveryAddress = "delivery_address"
        case shippingAddress = "shipping_address"
        case address
        case pickupTime = "pickup_time"
        case pickupAt = "pickup_at"
        case scheduledFor = "scheduled_for"
        case scheduledAt = "scheduled_at"
        case createdAt = "created_at"
        case elapsedMinutes = "elapsed_minutes"
        case customer
        case notes
        case items
        case totals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let flexibleContainer = try decoder.container(keyedBy: FlexibleCodingKey.self)
        id = try container.decode(Int.self, forKey: .id)
        orderNumber = try container.decode(String.self, forKey: .orderNumber)
        status = try container.decode(KitchenOnlineOrderStatus.self, forKey: .status)
        fulfillmentMethod = try container.decodeIfPresent(String.self, forKey: .fulfillmentMethod)
        paymentMethod = try container.decodeIfPresent(String.self, forKey: .paymentMethod)
        paymentStatus = try container.decodeIfPresent(String.self, forKey: .paymentStatus)
        deliveryRecipientName = try flexibleContainer.decodeFirstPresentStringOrNested(
            keys: ["recipient_name", "delivery_recipient_name", "delivery", "shipping"],
            nestedKeys: ["recipient_name", "name", "customer_name"]
        )
        deliveryPhone = try flexibleContainer.decodeFirstPresentStringOrNested(
            keys: ["delivery_phone", "phone", "delivery", "shipping"],
            nestedKeys: ["phone", "delivery_phone", "customer_phone"]
        )
        deliveryAddress = try flexibleContainer.decodeFirstPresentStringOrNested(
            keys: [
                "delivery_address",
                "shipping_address",
                "customer_address",
                "address",
                "deliveryAddress",
                "shippingAddress",
                "delivery",
                "shipping",
                "fulfillment"
            ],
            nestedKeys: [
                "full_address",
                "formatted_address",
                "delivery_address",
                "shipping_address",
                "customer_address",
                "address",
                "street",
                "line1",
                "line_1",
                "address_line_1"
            ]
        )
        deliveryAddressVerified = (try? flexibleContainer.decodeFirstPresentBoolOrNested(
            keys: ["address_verified", "delivery_address_verified", "delivery", "shipping", "fulfillment"],
            nestedKeys: ["address_verified", "delivery_address_verified", "verified"]
        )) ?? false
        pickupTime = try flexibleContainer.decodeFirstPresentStringOrNested(
            keys: [
                "pickup_time",
                "pickup_at",
                "scheduled_for",
                "scheduled_at",
                "pickupTime",
                "pickupAt",
                "fulfillment"
            ],
            nestedKeys: [
                "pickup_time",
                "pickup_at",
                "scheduled_for",
                "scheduled_at",
                "time",
                "ready_at"
            ]
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        elapsedMinutes = try container.decode(Int.self, forKey: .elapsedMinutes)
        customer = try container.decode(KitchenCustomer.self, forKey: .customer)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        items = try container.decode([KitchenOnlineOrderItem].self, forKey: .items)
        totals = try container.decode(KitchenOnlineTotals.self, forKey: .totals)
    }

    var customerDisplay: String {
        customer.name?.isEmpty == false ? customer.name! : "Guest order"
    }

    var contactName: String {
        if isDelivery, let name = deliveryRecipientName?.nilIfBlank {
            return name
        }

        return customerDisplay
    }

    var contactPhone: String? {
        if isDelivery, let phone = deliveryPhone?.nilIfBlank {
            return phone
        }

        return customer.phone?.nilIfBlank
    }

    var cardContactText: String {
        [contactName.nilIfBlank, contactPhone]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfBlank ?? "Guest order"
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

    var isDelivery: Bool {
        let value = fulfillmentMethod?.lowercased() ?? ""
        return value.contains("deliver")
            || value.contains("ship")
            || deliveryAddress?.nilIfBlank != nil
            || totals.deliveryFee > 0
    }

    var typeText: String {
        isDelivery ? "Online Delivery" : "Online Pick Up"
    }

    var fulfillmentIcon: String {
        isDelivery ? "scooter" : "takeoutbag.and.cup.and.straw"
    }

    var destinationText: String {
        if isDelivery {
            return deliveryAddress?.nilIfBlank ?? "Address not provided"
        }

        return pickupTime?.nilIfBlank ?? "Pickup time not provided"
    }

    var paymentSummaryText: String {
        [paymentMethod?.humanized, paymentStatus?.humanized]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: " · ")
            .nilIfBlank ?? "Not provided"
    }

    var requiresConfirmedPaymentBeforeKitchen: Bool {
        paymentMethod?.lowercased() == "bank_qr"
    }

    var isPaymentConfirmedForKitchen: Bool {
        !requiresConfirmedPaymentBeforeKitchen || paymentStatus?.lowercased() == "paid"
    }

    var canMarkPaid: Bool {
        status == .accepted
            && requiresConfirmedPaymentBeforeKitchen
            && paymentStatus?.lowercased() != "paid"
    }

    var canSendToKitchen: Bool {
        status == .accepted && isPaymentConfirmedForKitchen
    }

    var acceptedStateText: String {
        if canSendToKitchen {
            return "Paid. Ready for kitchen."
        }

        if requiresConfirmedPaymentBeforeKitchen {
            return "Accepted. Waiting for QR payment."
        }

        return "Accepted. Ready for kitchen."
    }

    var needsAddressVerification: Bool {
        isDelivery && !deliveryAddressVerified
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

    var toppingText: String {
        toppings.map(\.displayName).joined(separator: ", ")
    }
}

struct KitchenOnlineOrderTopping: Identifiable, Decodable, Equatable {
    let id: Int
    let name: String?
    let quantity: Int

    var displayName: String {
        guard let name, !name.isEmpty else { return "Topping" }
        return name
    }
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

struct CompletedKitchenTicket: Identifiable, Codable, Equatable {
    let id: Int
    let orderNumber: String
    let source: String
    let customerName: String
    let customerPhone: String?
    let fulfillmentMethod: String?
    let deliveryAddress: String?
    let pickupTime: String?
    let paymentMethod: String?
    let notes: String?
    let total: Double?
    let items: [CompletedKitchenTicketItem]
    let archivedAt: Date

    init(order: KitchenOrder, onlineDetails: KitchenOnlineOrder?, archivedAt: Date) {
        id = order.id
        orderNumber = order.orderNumber
        source = order.source.shortLabel
        customerName = order.customerDisplay
        customerPhone = onlineDetails?.customer.phone ?? order.customer.phone
        fulfillmentMethod = onlineDetails?.fulfillmentMethod
        deliveryAddress = onlineDetails?.deliveryAddress
        pickupTime = onlineDetails?.pickupTime
        paymentMethod = order.paymentMethod ?? onlineDetails?.paymentMethod
        notes = onlineDetails?.notes ?? order.notes
        total = order.totals?.total ?? onlineDetails?.totals.total
        items = order.items.map { CompletedKitchenTicketItem(item: $0) }
        self.archivedAt = archivedAt
    }

    var isDelivery: Bool {
        let value = fulfillmentMethod?.lowercased() ?? ""
        return value.contains("deliver") || value.contains("ship") || deliveryAddress?.nilIfBlank != nil
    }

    var typeText: String {
        source == "STORE" ? "Store" : (isDelivery ? "Online Delivery" : "Online Pick Up")
    }

    var fulfillmentIcon: String {
        source == "STORE" ? "storefront" : (isDelivery ? "scooter" : "takeoutbag.and.cup.and.straw")
    }

    var destinationText: String {
        if isDelivery {
            return deliveryAddress?.nilIfBlank ?? "Address not provided"
        }

        return pickupTime?.nilIfBlank ?? "Pickup time not provided"
    }

    var totalText: String {
        guard let total else { return "-" }
        return "\(Int(total).formatted()) VND"
    }

    var paymentText: String {
        paymentMethod?.paymentDisplayText ?? "Not recorded"
    }

    var completedText: String {
        archivedAt.formatted(date: .omitted, time: .shortened)
    }

    var completedDateText: String {
        completedFormatter("dd MMM yyyy").string(from: archivedAt)
    }

    var completedTimeText: String {
        completedFormatter("HH:mm").string(from: archivedAt)
    }

    private func completedFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        return formatter
    }
}

struct CompletedKitchenTicketItem: Identifiable, Codable, Equatable {
    let id: Int
    let productName: String
    let quantity: Int
    let lineTotal: Double?
    let toppings: [CompletedKitchenTicketTopping]
    let notes: String?

    init(item: KitchenItem) {
        id = item.id
        productName = item.productName
        quantity = item.quantity
        lineTotal = item.lineTotal
        toppings = item.toppings.map { CompletedKitchenTicketTopping(topping: $0) }
        notes = item.notes
    }

    var priceText: String {
        guard let lineTotal else { return "-" }
        return "\(Int(lineTotal).formatted()) VND"
    }

    var toppingText: String {
        toppings
            .map { topping in
                topping.quantity > 1 ? "\(topping.quantity)x \(topping.name)" : topping.name
            }
            .joined(separator: ", ")
    }
}

struct CompletedKitchenTicketTopping: Identifiable, Codable, Equatable {
    let id: Int
    let name: String
    let quantity: Int

    init(topping: KitchenTopping) {
        id = topping.id
        name = topping.displayName
        quantity = topping.quantity
    }
}

private enum CompletedKitchenTicketStore {
    private static let key = "CompletedKitchenTickets"

    static func load() -> [CompletedKitchenTicket] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let tickets = try? JSONDecoder().decode([CompletedKitchenTicket].self, from: data) else {
            return []
        }

        let cutoff = vietnamStartOfToday()
        return tickets
            .filter { $0.archivedAt >= cutoff }
            .sorted { $0.archivedAt > $1.archivedAt }
    }

    static func vietnamStartOfToday(now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current

        return calendar.startOfDay(for: now)
    }

    static func save(_ tickets: [CompletedKitchenTicket]) {
        guard let data = try? JSONEncoder().encode(tickets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
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
    let paymentMethod: String?
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
        case paymentMethod = "payment_method"
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

    var paymentText: String {
        paymentMethod?.paymentDisplayText ?? "Not recorded"
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
    let lineTotal: Double?
    let toppings: [KitchenTopping]
    let notes: String?
    let kitchenStatus: KitchenStatus

    enum CodingKeys: String, CodingKey {
        case id
        case productName = "product_name"
        case quantity
        case lineTotal = "line_total"
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

    var userFacingMessage: String {
        switch self {
        case .invalidURL:
            return "Kitchen URL is invalid."
        case .invalidResponse:
            return "Kitchen API response was invalid."
        case .unauthorized:
            return "Kitchen token rejected."
        case .server(let code, _):
            return "Kitchen API error \(code)."
        case .serverMessage(_, _, let message):
            return message
        }
    }
}

private extension Error {
    var isValidationFailure: Bool {
        guard let apiError = self as? KitchenAPIError else { return false }

        switch apiError {
        case .server(let code, _), .serverMessage(let code, _, _):
            return code == 422
        default:
            return false
        }
    }

    var posReviewReason: String {
        guard let apiError = self as? KitchenAPIError else {
            return localizedDescription
        }

        return apiError.userFacingMessage
    }
}

extension JSONDecoder {
    static var kitchen: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var kitchen: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension KeyedDecodingContainer {
    func decodeFirstPresentString(for keys: [Key]) throws -> String? {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key)?.nilIfBlank {
                return value
            }
        }

        return nil
    }
}

private struct FlexibleCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == FlexibleCodingKey {
    func decodeFirstPresentStringOrNested(keys: [String], nestedKeys: [String]) throws -> String? {
        for key in keys {
            guard let codingKey = FlexibleCodingKey(stringValue: key), contains(codingKey) else {
                continue
            }

            if let value = (try? decodeIfPresent(String.self, forKey: codingKey))?.nilIfBlank {
                return value
            }

            if let nested = try? nestedContainer(keyedBy: FlexibleCodingKey.self, forKey: codingKey) {
                if let value = try nested.decodeFirstPresentString(keys: nestedKeys) {
                    return value
                }

                if let value = try nested.decodeAddressParts() {
                    return value
                }
            }
        }

        return nil
    }

    func decodeFirstPresentBoolOrNested(keys: [String], nestedKeys: [String]) throws -> Bool? {
        for key in keys {
            guard let codingKey = FlexibleCodingKey(stringValue: key), contains(codingKey) else {
                continue
            }

            if let value = try? decodeIfPresent(Bool.self, forKey: codingKey) {
                return value
            }

            if let nested = try? nestedContainer(keyedBy: FlexibleCodingKey.self, forKey: codingKey),
               let value = try nested.decodeFirstPresentBool(keys: nestedKeys) {
                return value
            }
        }

        return nil
    }

    func decodeFirstPresentString(keys: [String]) throws -> String? {
        for key in keys {
            guard let codingKey = FlexibleCodingKey(stringValue: key),
                  let value = (try? decodeIfPresent(String.self, forKey: codingKey))?.nilIfBlank else {
                continue
            }

            return value
        }

        return nil
    }

    func decodeFirstPresentBool(keys: [String]) throws -> Bool? {
        for key in keys {
            guard let codingKey = FlexibleCodingKey(stringValue: key),
                  let value = try? decodeIfPresent(Bool.self, forKey: codingKey) else {
                continue
            }

            return value
        }

        return nil
    }

    func decodeAddressParts() throws -> String? {
        let parts = try [
            decodeFirstPresentString(keys: ["line1", "line_1", "address_line_1", "street"]),
            decodeFirstPresentString(keys: ["line2", "line_2", "address_line_2"]),
            decodeFirstPresentString(keys: ["ward"]),
            decodeFirstPresentString(keys: ["district"]),
            decodeFirstPresentString(keys: ["city", "province"])
        ]
            .compactMap { $0 }

        return parts.joined(separator: ", ").nilIfBlank
    }
}

private extension Double {
    var currencyText: String {
        "\(Int(self).formatted()) VND"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var humanized: String {
        replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    var paymentDisplayText: String {
        switch trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cash":
            return "Cash"
        case "bank":
            return "Bank"
        case "qr", "bank_qr":
            return "QR"
        case "card":
            return "Card"
        default:
            return humanized.nilIfBlank ?? "Not recorded"
        }
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

enum AppPalette {
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
    ContentView(startsPolling: false, showsSplash: false)
}

#Preview("iPhone Shell") {
    ContentView(startsPolling: false, showsSplash: false)
        .environment(\.horizontalSizeClass, .compact)
        .frame(width: 393, height: 852)
}

#Preview("Launch Splash") {
    LaunchSplashView(wallpaperAssetName: "POSLightWallpaper", accentColor: AppPalette.orange) {}
}
