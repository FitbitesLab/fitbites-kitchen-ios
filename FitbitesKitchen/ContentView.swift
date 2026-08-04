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

struct ContentView: View {
    @StateObject private var store = KitchenStore()
    @State private var selectedStatus: KitchenStatus? = nil
    @State private var selectedSource: KitchenSource? = nil
    @State private var selectedOrder: KitchenOrder?
    @State private var pendingOnlineOrderAction: OnlineOrderAction?
    @State private var pendingKitchenCancelOrder: KitchenOrder?
    @State private var settingsOpen = false

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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HeaderView(
                            activeCount: store.orders.count,
                            readyCount: store.summary.ready,
                            oldestMinutes: store.oldestElapsedMinutes,
                            isConnected: store.isConnected
                        )

                        MetricsStrip(summary: store.summary)

                        FilterBar(
                            selectedSource: $selectedSource,
                            selectedStatus: $selectedStatus,
                            sources: store.availableSources
                        )

                        if let message = store.errorMessage {
                            ErrorBanner(message: message) {
                                Task { await store.refresh(forceChime: false) }
                            }
                        }

                        OnlineOrderReviewSection(
                            orders: store.onlineOrders,
                            onAccept: { order in
                                pendingOnlineOrderAction = .accept(order)
                            },
                            onDecline: { order in
                                pendingOnlineOrderAction = .decline(order)
                            }
                        )

                        QueueSection(
                            orders: filteredOrders,
                            isLoading: store.isLoading,
                            onSelect: { selectedOrder = $0 },
                            onStatus: { order, status in
                                handleStatus(order: order, status: status)
                            }
                        )
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
                .refreshable {
                    await store.refresh(forceChime: false)
                }
            }
            .navigationTitle("Fitbites Kitchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.refresh(forceChime: false) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settingsOpen = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .task {
                store.start()
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
    @Published var isLoading = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var baseURL = UserDefaults.standard.string(forKey: "KitchenBaseURL") ?? "http://127.0.0.1:8000"
    @Published var kitchenToken = UserDefaults.standard.string(forKey: "KitchenToken") ?? ""

    private var pollTask: Task<Void, Never>?
    private var knownOrderIDs = Set<Int>()
    private var knownOnlineOrderIDs = Set<Int>()
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
        chime.play()
    }

    func stopChime() {
        chime.stop()
    }

    func refresh(forceChime: Bool) async {
        guard !kitchenToken.isEmpty else {
            errorMessage = "Add the kitchen token in Settings."
            isConnected = false
            return
        }

        isLoading = orders.isEmpty

        do {
            let client = KitchenAPIClient(baseURL: baseURL, token: kitchenToken)
            let onlinePayload = try await client.fetchOnlineOrders()
            let kitchenPayload = try await client.fetchOrders()
            let incomingIDs = Set(kitchenPayload.orders.map(\.id))
            let incomingOnlineIDs = Set(onlinePayload.onlineOrders.map(\.id))
            let newOnlineIDs = incomingOnlineIDs.subtracting(knownOnlineOrderIDs)

            onlineOrders = onlinePayload.onlineOrders
            orders = kitchenPayload.orders
            summary = kitchenPayload.summary
            knownOrderIDs = incomingIDs
            knownOnlineOrderIDs = incomingOnlineIDs
            errorMessage = nil
            isConnected = true

            if forceChime && !newOnlineIDs.isEmpty {
                chime.play()
            }
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }

        isLoading = false
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

struct KitchenAPIClient {
    let baseURL: String
    let token: String

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
                throw KitchenAPIError.serverMessage(httpResponse.statusCode, message)
            }

            throw KitchenAPIError.server(httpResponse.statusCode)
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

private final class KitchenChime: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?

    func play() {
        if player?.isPlaying == true {
            return
        }

        guard let url = Bundle.main.url(forResource: "fitbites-order-chime", withExtension: "mp3") else {
            AudioServicesPlaySystemSound(1005)
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
            AudioServicesPlaySystemSound(1005)
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

private struct HeaderView: View {
    let activeCount: Int
    let readyCount: Int
    let oldestMinutes: Int?
    let isConnected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Fitbites Kitchen")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                Text("Native rail connected to Ember OS")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.muted)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text("\(activeCount)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
                Text(readyCount > 0 ? "\(readyCount) ready" : oldestText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(readyCount > 0 ? AppPalette.green : AppPalette.orange)
                ConnectionDot(isConnected: isConnected)
            }
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var oldestText: String {
        guard let oldestMinutes else { return "waiting" }
        return oldestMinutes <= 1 ? "just in" : "oldest \(oldestMinutes)m"
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
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppPalette.muted)
        }
    }
}

private struct MetricsStrip: View {
    let summary: KitchenSummary

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
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
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FilterBar: View {
    @Binding var selectedSource: KitchenSource?
    @Binding var selectedStatus: KitchenStatus?
    let sources: [KitchenSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "All Sources", isSelected: selectedSource == nil) { selectedSource = nil }
                    ForEach(sources) { source in
                        FilterChip(title: source.rawValue, isSelected: selectedSource == source) { selectedSource = source }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "Active", isSelected: selectedStatus == nil) { selectedStatus = nil }
                    ForEach(KitchenStatus.activeFilters) { status in
                        FilterChip(title: status.label, isSelected: selectedStatus == status) { selectedStatus = status }
                    }
                }
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? .white : AppPalette.ink)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(isSelected ? AppPalette.ink : .white, in: RoundedRectangle(cornerRadius: 8))
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
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppPalette.ink)
            Spacer()
            Button("Retry", action: retry)
                .font(.footnote.weight(.bold))
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OnlineOrderReviewSection: View {
    let orders: [KitchenOnlineOrder]
    let onAccept: (KitchenOnlineOrder) -> Void
    let onDecline: (KitchenOnlineOrder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Online Orders")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Text("\(orders.count) waiting")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(orders.isEmpty ? AppPalette.muted : AppPalette.orange)
            }

            if orders.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(AppPalette.green)
                    Text("No online orders waiting for review.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppPalette.muted)
                    Spacer()
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(orders) { order in
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(order.orderNumber)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(order.customerDisplay)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppPalette.muted)
                }

                Spacer()

                Label(order.status == .submitted ? "Needs acceptance" : "Accepted", systemImage: "bell.badge")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.orange)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(AppPalette.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                Label("Website", systemImage: "globe")
                Label(order.elapsedText, systemImage: "clock")
                Label("\(order.itemCount) items", systemImage: "takeoutbag.and.cup.and.straw")
                Spacer()
                Text(order.totalText)
                    .font(.caption.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppPalette.muted)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(order.items.prefix(4)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.quantity)x")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(AppPalette.orange)
                            .frame(width: 30, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.productName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            if !item.toppings.isEmpty {
                                Text(item.toppings.compactMap(\.name).joined(separator: ", "))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(AppPalette.muted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if let notes = order.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(2)
            }

            if order.status == .submitted {
                HStack(spacing: 10) {
                    Button(action: onDecline) {
                        Text("Decline")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.ink)
                    .background(AppPalette.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                    Button(action: onAccept) {
                        Text("Accept")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(AppPalette.orange, in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                HStack(spacing: 10) {
                    Text("Accepted, not on the rail yet.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: onDecline) {
                        Label("Cancel", systemImage: "trash")
                            .font(.caption.weight(.bold))
                            .frame(height: 34)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.red)
                    .background(AppPalette.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppPalette.orange)
                .frame(width: 5)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

private struct QueueSection: View {
    let orders: [KitchenOrder]
    let isLoading: Bool
    let onSelect: (KitchenOrder) -> Void
    let onStatus: (KitchenOrder, KitchenStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Order Queue")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Text(isLoading ? "Loading" : "\(orders.count) tickets")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppPalette.muted)
            }

            if orders.isEmpty && !isLoading {
                EmptyKitchenView()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(orders) { order in
                        OrderCard(order: order, onSelect: { onSelect(order) }, onStatus: { onStatus(order, $0) })
                    }
                }
            }
        }
    }
}

private struct EmptyKitchenView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(AppPalette.green)
            Text("No active orders")
                .font(.title3.weight(.semibold))
            Text("The rail is clean. New Store, Website, Grab, and Shopee orders will appear here.")
                .font(.subheadline)
                .foregroundStyle(AppPalette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
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
                            .font(.caption2.weight(.bold))
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
                    header
                    meta
                    itemPreview
                }
            }
            .buttonStyle(.plain)

            Divider()

            HStack(spacing: 8) {
                ForEach(order.visibleActions) { status in
                    statusButton(status)
                }
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(order.status.tint)
                .frame(width: 5)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(order.orderNumber)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(order.customerDisplay)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.muted)
            }

            Spacer()

            StatusBadge(status: order.status)

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
        HStack(spacing: 10) {
            Label(order.source.rawValue, systemImage: order.source.icon)
            Label(order.elapsedText, systemImage: "clock")
            Label("\(order.itemCount) items", systemImage: "takeoutbag.and.cup.and.straw")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppPalette.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }

    private var itemPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(order.items.prefix(3)) { item in
                ItemPreviewLine(item: item)
            }
        }
    }

    private func statusButton(_ status: KitchenStatus) -> some View {
        Button {
            resetSwipe()
            onStatus(status)
        } label: {
            Text(status.actionLabel)
                .font(.caption.weight(.bold))
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
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(AppPalette.orange)
                .frame(width: 30, alignment: .leading)
            Text(item.productName)
                .font(.subheadline.weight(.semibold))
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
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(AppPalette.ink)
                        Text(order.customerDisplay)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(AppPalette.muted)
                    }

                    DetailSummary(order: order)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Items")
                            .font(.headline)
                            .foregroundStyle(AppPalette.ink)

                        ForEach(order.items) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text("\(item.quantity)x")
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(AppPalette.orange)
                                        .frame(width: 44, alignment: .leading)

                                    Text(item.productName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(AppPalette.ink)

                                    Spacer()
                                }

                                if !item.toppings.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(item.toppings) { topping in
                                            Text("+ \(topping.displayName) x \(topping.quantity)")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(AppPalette.muted)
                                        }
                                    }
                                    .padding(.leading, 56)
                                }
                            }
                            .padding(12)
                            .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
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
                            .font(.callout.weight(.bold))
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
                    .font(.caption)
                    .foregroundStyle(AppPalette.muted)
                Text(value)
                    .font(.subheadline.weight(.bold))
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
            .font(.caption.weight(.bold))
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
                    Button("Test Fitbites Chime") {
                        store.playTestChime()
                    }

                    Button("Stop Chime") {
                        store.stopChime()
                    }
                    .foregroundStyle(AppPalette.red)
                }

                Section {
                    Button("Save and Refresh") {
                        store.saveSettings(baseURL: baseURL, token: token)
                        dismiss()
                    }
                    .font(.headline)
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
    case server(Int)
    case serverMessage(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Kitchen URL is invalid."
        case .invalidResponse: "Kitchen API response was invalid."
        case .unauthorized: "Kitchen token rejected."
        case .server(let code): "Kitchen API error \(code)."
        case .serverMessage(let code, let message): "Kitchen API error \(code): \(message)"
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

private enum AppPalette {
    static let background = Color(red: 0.965, green: 0.962, blue: 0.948)
    static let ink = Color(red: 0.14, green: 0.11, blue: 0.09)
    static let muted = Color(red: 0.48, green: 0.44, blue: 0.39)
    static let orange = Color(red: 0.74, green: 0.39, blue: 0.13)
    static let red = Color(red: 0.68, green: 0.22, blue: 0.16)
    static let green = Color(red: 0.13, green: 0.42, blue: 0.18)
    static let blue = Color(red: 0.20, green: 0.36, blue: 0.52)
}

#Preview {
    ContentView()
}
