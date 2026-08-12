//
//  Studio.swift
//  FitbitesKitchen
//
//  Hidden native analytics surface for EmberOS.
//

import SwiftUI
import Foundation
import Combine

enum StudioTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case reports = "Reports"
    case payments = "Payments"
    case trends = "Trends"
    case compare = "Compare"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "chart.bar"
        case .reports: "list.bullet.rectangle"
        case .payments: "creditcard"
        case .trends: "waveform.path.ecg"
        case .compare: "arrow.left.arrow.right"
        }
    }
}

enum StudioArea: String, CaseIterable, Identifiable {
    case sales = "Sales"
    case inventory = "Inventory"
    case team = "Team"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sales: "chart.line.uptrend.xyaxis"
        case .inventory: "shippingbox"
        case .team: "person.2"
        }
    }
}

enum StudioInventoryTab: String, CaseIterable, Identifiable {
    case products = "Products"
    case ingredients = "Ingredients"
    case recipeLab = "Recipe Lab"
    case planning = "Planning"

    var id: String { rawValue }

    static var essentialsCases: [StudioInventoryTab] {
        [.products, .ingredients, .recipeLab]
    }

    var icon: String {
        switch self {
        case .products: "square.grid.2x2"
        case .ingredients: "leaf"
        case .recipeLab: "flask"
        case .planning: "checklist"
        }
    }
}

@MainActor
final class StudioStore: ObservableObject {
    @Published var payload: StudioSalesPayload?
    @Published var inventoryPayload: StudioInventoryPayload?
    @Published var selectedArea: StudioArea = .sales
    @Published var selectedTab: StudioTab = .overview
    @Published var selectedInventoryTab: StudioInventoryTab = .products
    @Published var selectedPeriod: String = "this_month"
    @Published var compareProductA = ""
    @Published var compareProductB = ""
    @Published var compareMetric = "revenue"
    @Published var isLoading = false
    @Published var isConnected = false
    @Published var errorMessage: String?

    private var activeTask: Task<Void, Never>?

    func refresh(baseURL: String, token: String) async {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            errorMessage = "Add the Studio token in Settings."
            isConnected = false
            return
        }

        activeTask?.cancel()
        isLoading = true

        let period = Self.normalizedPeriod(selectedPeriod)
        let compareA = compareProductA.trimmingCharacters(in: .whitespacesAndNewlines)
        let compareB = compareProductB.trimmingCharacters(in: .whitespacesAndNewlines)
        let metric = compareMetric
        let task = Task {
            do {
                let client = StudioAPIClient(baseURL: baseURL, token: cleanToken)
                let response = try await client
                    .fetchSales(period: period, compareA: compareA, compareB: compareB, compareMetric: metric)
                let inventoryResponse = try? await client.fetchInventory()

                guard !Task.isCancelled else { return }

                payload = response
                inventoryPayload = inventoryResponse
                if compareProductA.isEmpty {
                    compareProductA = response.compare.productA
                }
                if compareProductB.isEmpty {
                    compareProductB = response.compare.productB
                }
                compareMetric = response.compare.metric
                errorMessage = nil
                isConnected = true
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }

                errorMessage = error.localizedDescription
                isConnected = false
                isLoading = false
            }
        }

        activeTask = task
        await task.value
    }

    func updateInventory(baseURL: String, token: String, action: @escaping (StudioAPIClient) async throws -> StudioInventoryPayload) async {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            errorMessage = "Add the Studio token in Settings."
            isConnected = false
            return
        }

        isLoading = true

        do {
            let response = try await action(StudioAPIClient(baseURL: baseURL, token: cleanToken))
            inventoryPayload = response
            errorMessage = nil
            isConnected = true
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
            isLoading = false
        }
    }

    private static func normalizedPeriod(_ period: String) -> String {
        switch period {
        case "day":
            return "today"
        case "week":
            return "this_week"
        case "month":
            return "this_month"
        case "year":
            return "this_year"
        default:
            return period
        }
    }
}

struct StudioAPIClient {
    let baseURL: String
    let token: String

    func fetchSales(period: String, compareA: String, compareB: String, compareMetric: String) async throws -> StudioSalesPayload {
        var components = URLComponents()
        components.path = "/api/studio/sales"
        var queryItems = [URLQueryItem(name: "period", value: period)]
        if !compareA.isEmpty {
            queryItems.append(URLQueryItem(name: "compare_a", value: compareA))
        }
        if !compareB.isEmpty {
            queryItems.append(URLQueryItem(name: "compare_b", value: compareB))
        }
        queryItems.append(URLQueryItem(name: "compare_metric", value: compareMetric))
        components.queryItems = queryItems
        return try await request(path: components.string ?? "/api/studio/sales")
    }

    func fetchInventory() async throws -> StudioInventoryPayload {
        try await request(path: "/api/studio/inventory")
    }

    func createInventoryCategory(_ payload: StudioInventoryCategoryRequest) async throws -> StudioInventoryPayload {
        try await request(path: "/api/studio/inventory/categories", method: "POST", body: payload)
    }

    func createInventoryItem(_ payload: StudioInventoryItemRequest) async throws -> StudioInventoryPayload {
        try await request(path: "/api/studio/inventory/items", method: "POST", body: payload)
    }

    func updateInventoryItem(id: Int, payload: StudioInventoryItemRequest) async throws -> StudioInventoryPayload {
        try await request(path: "/api/studio/inventory/items/\(id)", method: "PATCH", body: payload)
    }

    func adjustInventoryStock(id: Int, payload: StudioInventoryStockRequest) async throws -> StudioInventoryPayload {
        try await request(path: "/api/studio/inventory/items/\(id)/stock", method: "POST", body: payload)
    }

    func deleteInventoryItem(id: Int) async throws -> StudioInventoryPayload {
        try await request(path: "/api/studio/inventory/items/\(id)", method: "DELETE")
    }

    private func request<Response: Decodable>(path: String, method: String = "GET") async throws -> Response {
        try await request(path: path, method: method, bodyData: nil)
    }

    private func request<Response: Decodable, Body: Encodable>(path: String, method: String, body: Body) async throws -> Response {
        try await request(path: path, method: method, bodyData: try JSONEncoder().encode(body))
    }

    private func request<Response: Decodable>(path: String, method: String, bodyData: Data?) async throws -> Response {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw StudioAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 14
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Studio-Token")
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StudioAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 403 {
                throw StudioAPIError.unauthorized
            }

            if let apiError = try? JSONDecoder.kitchen.decode(StudioAPIErrorResponse.self, from: data),
               let message = apiError.displayMessage {
                throw StudioAPIError.serverMessage(message)
            }

            throw StudioAPIError.server(httpResponse.statusCode)
        }

        return try JSONDecoder.kitchen.decode(Response.self, from: data)
    }
}

enum StudioAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(Int)
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid Studio URL."
        case .invalidResponse: "Studio returned an invalid response."
        case .unauthorized: "Studio token rejected."
        case .server(let code): "Studio request failed with \(code)."
        case .serverMessage(let message): message
        }
    }
}

struct StudioSalesPayload: Decodable {
    let period: StudioPeriod
    let summary: StudioSummary
    let overview: StudioOverview
    let reports: StudioReports
    let payments: StudioPayments
    let trends: StudioTrends
    let compare: StudioCompare
}

struct StudioInventoryPayload: Decodable {
    let summary: StudioInventorySummary
    let products: [StudioInventoryItem]
    let ingredients: [StudioInventoryItem]
    let planning: [StudioInventoryPlanningRow]
    let recipes: [StudioInventoryRecipe]
    let movements: [StudioInventoryMovement]
}

struct StudioInventorySummary: Decodable {
    let totalItems: Int
    let products: Int
    let ingredients: Int
    let lowStock: Int
    let inventoryValue: Double

    enum CodingKeys: String, CodingKey {
        case products, ingredients
        case totalItems = "total_items"
        case lowStock = "low_stock"
        case inventoryValue = "inventory_value"
    }
}

struct StudioInventoryItem: Decodable, Identifiable {
    let id: Int
    let name: String
    let type: String
    let category: String
    let currentStock: Double
    let minimumStock: Double
    let unit: String
    let costPerUnit: Double
    let sellingPrice: Double
    let imageURL: String?
    let posCategory: String?
    let linkedToPOS: Bool
    let isLowStock: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type, category, unit
        case currentStock = "current_stock"
        case minimumStock = "minimum_stock"
        case costPerUnit = "cost_per_unit"
        case sellingPrice = "selling_price"
        case imageURL = "image_url"
        case posCategory = "pos_category"
        case linkedToPOS = "linked_to_pos"
        case isLowStock = "is_low_stock"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        category = try container.decode(String.self, forKey: .category)
        currentStock = try container.decode(Double.self, forKey: .currentStock)
        minimumStock = try container.decode(Double.self, forKey: .minimumStock)
        unit = try container.decode(String.self, forKey: .unit)
        costPerUnit = try container.decode(Double.self, forKey: .costPerUnit)
        sellingPrice = try container.decode(Double.self, forKey: .sellingPrice)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
        posCategory = try container.decodeIfPresent(String.self, forKey: .posCategory)
        let explicitPOSLink = try container.decodeIfPresent(Bool.self, forKey: .linkedToPOS)
        linkedToPOS = explicitPOSLink ?? (posCategory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || type == "product")
        isLowStock = try container.decodeIfPresent(Bool.self, forKey: .isLowStock) ?? (minimumStock > 0 && currentStock <= minimumStock)
    }
}

struct StudioInventoryPlanningRow: Decodable, Identifiable {
    let id: Int
    let name: String
    let type: String
    let action: String
    let currentStock: Double
    let minimumStock: Double
    let unit: String
    let averageDaily7: Double?
    let daysRemaining: Double?
    let suggestedQuantity: Double
    let isLowStock: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type, action, unit
        case currentStock = "current_stock"
        case minimumStock = "minimum_stock"
        case averageDaily7 = "average_daily_7"
        case daysRemaining = "days_remaining"
        case suggestedQuantity = "suggested_quantity"
        case isLowStock = "is_low_stock"
    }
}

struct StudioInventoryRecipe: Decodable, Identifiable {
    let id: Int
    let name: String
    let type: String
    let componentCount: Int
    let recipeCost: Double?
    let sellingPrice: Double?
    let grossProfit: Double?
    let grossMarginPercent: Double?
    let foodCostPercent: Double?
    let canProduce: Bool?
    let maxProduce: Double?
    let components: [StudioInventoryRecipeComponent]

    enum CodingKeys: String, CodingKey {
        case id, name, type, components
        case componentCount = "component_count"
        case recipeCost = "recipe_cost"
        case sellingPrice = "selling_price"
        case grossProfit = "gross_profit"
        case grossMarginPercent = "gross_margin_percent"
        case foodCostPercent = "food_cost_percent"
        case canProduce = "can_produce"
        case maxProduce = "max_produce"
    }
}

struct StudioInventoryRecipeComponent: Decodable, Identifiable {
    var id: String { "\(componentID ?? childItemID ?? 0)-\(name)-\(unit)" }
    let componentID: Int?
    let childItemID: Int?
    let name: String
    let quantity: Double
    let unit: String
    let available: Double
    let neededPerBatch: Double?
    let shortage: Double?
    let cost: Double?
    let canProduce: Double?

    enum CodingKeys: String, CodingKey {
        case name, quantity, unit, available, cost
        case componentID = "id"
        case childItemID = "child_item_id"
        case neededPerBatch = "needed_per_batch"
        case shortage
        case canProduce = "can_produce"
    }
}

struct StudioInventoryMovement: Decodable, Identifiable {
    let id: Int
    let itemName: String
    let type: String
    let quantity: Double
    let unit: String
    let note: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, quantity, unit, note
        case itemName = "item_name"
        case createdAt = "created_at"
    }
}

struct StudioInventoryCategoryRequest: Encodable {
    let name: String
    let kind: String
}

struct StudioInventoryItemRequest: Encodable {
    let mode: String
    let name: String
    let sku: String?
    let unit: String
    let currentStock: Double
    let minimumStock: Double
    let type: String
    let costPerUnit: Double
    let sellingPrice: Double
    let linkToPOS: Bool
    let inventoryCategory: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case mode, name, sku, unit, type, description
        case currentStock = "current_stock"
        case minimumStock = "minimum_stock"
        case costPerUnit = "cost_per_unit"
        case sellingPrice = "selling_price"
        case linkToPOS = "link_to_pos"
        case inventoryCategory = "inventory_category"
    }
}

struct StudioInventoryStockRequest: Encodable {
    let direction: String
    let amount: Double
}

struct StudioPeriod: Decodable {
    let preset: String
    let label: String
    let startDate: String
    let endDate: String

    enum CodingKeys: String, CodingKey {
        case preset, label
        case startDate = "start_date"
        case endDate = "end_date"
    }
}

struct StudioSummary: Decodable {
    let revenue: Double
    let orders: Int
    let averageTicket: Double
    let customersServed: Int
    let bestSeller: StudioProductMetric?

    enum CodingKeys: String, CodingKey {
        case revenue, orders
        case averageTicket = "average_ticket"
        case customersServed = "customers_served"
        case bestSeller = "best_seller"
    }
}

struct StudioOverview: Decodable {
    let daily: [StudioDailyMetric]
    let sourceMix: [StudioSourceMetric]
    let topProducts: [StudioProductMetric]

    enum CodingKeys: String, CodingKey {
        case daily
        case sourceMix = "source_mix"
        case topProducts = "top_products"
    }
}

struct StudioReports: Decodable {
    let groups: [StudioReportGroup]
}

struct StudioPayments: Decodable {
    let summary: [StudioPaymentMetric]
    let rows: [StudioPaymentRow]
    let history: [StudioPaymentHistoryGroup]
    let totalRevenue: Double

    enum CodingKeys: String, CodingKey {
        case summary, rows, history
        case totalRevenue = "total_revenue"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode([StudioPaymentMetric].self, forKey: .summary)
        rows = try container.decode([StudioPaymentRow].self, forKey: .rows)
        history = try container.decodeIfPresent([StudioPaymentHistoryGroup].self, forKey: .history) ?? []
        totalRevenue = try container.decode(Double.self, forKey: .totalRevenue)
    }
}

struct StudioTrends: Decodable {
    let summary: StudioTrendSummary
    let hours: [StudioHourMetric]
    let insights: [StudioInsight]
}

struct StudioCompare: Decodable {
    let products: [String]
    let productA: String
    let productB: String
    let metric: String
    let totalA: Double
    let totalB: Double
    let differencePercent: Double
    let series: [StudioComparePoint]

    enum CodingKeys: String, CodingKey {
        case products, metric, series
        case productA = "product_a"
        case productB = "product_b"
        case totalA = "total_a"
        case totalB = "total_b"
        case differencePercent = "difference_percent"
    }
}

struct StudioProductMetric: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let quantity: Double
    let revenue: Double
}

struct StudioDailyMetric: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let label: String
    let orders: Int
    let revenue: Double
}

struct StudioSourceMetric: Decodable, Identifiable {
    var id: String { source }
    let source: String
    let label: String
    let orders: Int
    let revenue: Double
}

struct StudioReportGroup: Decodable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let orders: Int
    let revenue: Double
    let days: [StudioDailyMetric]
}

struct StudioPaymentMetric: Decodable, Identifiable {
    var id: String { method }
    let method: String
    let label: String
    let orders: Int
    let revenue: Double
}

struct StudioPaymentRow: Decodable, Identifiable {
    let id: Int
    let orderNumber: String
    let method: String
    let methodLabel: String
    let sourceLabel: String
    let total: Double
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, method, total
        case orderNumber = "order_number"
        case methodLabel = "method_label"
        case sourceLabel = "source_label"
        case createdAt = "created_at"
    }
}

struct StudioPaymentHistoryGroup: Decodable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let orders: Int
    let revenue: Double
    let days: [StudioPaymentHistoryDay]
}

struct StudioPaymentHistoryDay: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let label: String
    let orders: Int
    let revenue: Double
    let rows: [StudioPaymentRow]
}

private enum StudioDateFormatters {
    static let apiDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "E, d MMM"
        return formatter
    }()

    static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isoDate(from value: String) -> Date? {
        isoPlain.date(from: value) ?? isoFractional.date(from: value)
    }
}

struct StudioTrendSummary: Decodable {
    let totalOrders: Int
    let totalRevenue: Double
    let averageOrderValue: Double
    let peakHour: String
    let peakOrders: Int

    enum CodingKeys: String, CodingKey {
        case totalOrders = "total_orders"
        case totalRevenue = "total_revenue"
        case averageOrderValue = "average_order_value"
        case peakHour = "peak_hour"
        case peakOrders = "peak_orders"
    }
}

struct StudioHourMetric: Decodable, Identifiable {
    var id: String { hour }
    let hour: String
    let orders: Int
    let revenue: Double
    let averageOrderValue: Double

    enum CodingKeys: String, CodingKey {
        case hour, orders, revenue
        case averageOrderValue = "average_order_value"
    }
}

struct StudioInsight: Decodable, Identifiable {
    var id: String { title + body }
    let title: String
    let body: String
}

struct StudioComparePoint: Decodable, Identifiable {
    var id: String { label }
    let label: String
    let a: Double
    let b: Double
}

struct StudioRootView: View {
    @ObservedObject var store: StudioStore
    let baseURL: String
    let studioToken: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioNavigationBar(
                selectedArea: $store.selectedArea,
                selectedSalesTab: $store.selectedTab,
                selectedInventoryTab: $store.selectedInventoryTab,
                accentColor: accentColor
            )

            if let errorMessage = store.errorMessage {
                StudioNotice(message: errorMessage, accentColor: accentColor) {
                    Task { await store.refresh(baseURL: baseURL, token: studioToken) }
                }
            }

            if let payload = store.payload {
                switch store.selectedArea {
                case .sales:
                    StudioContent(
                        payload: payload,
                        selectedPeriod: store.selectedPeriod,
                        selectedTab: store.selectedTab,
                        compareProductA: store.compareProductA,
                        compareProductB: store.compareProductB,
                        compareMetric: store.compareMetric,
                        accentColor: accentColor
                    ) { productA, productB, metric in
                        store.compareProductA = productA
                        store.compareProductB = productB
                        store.compareMetric = metric
                        Task { await store.refresh(baseURL: baseURL, token: studioToken) }
                    }
                case .inventory:
                    if let inventoryPayload = store.inventoryPayload {
                        StudioInventoryContent(
                            payload: inventoryPayload,
                            selectedTab: store.selectedInventoryTab,
                            accentColor: accentColor,
                            onCreateCategory: { request in
                                await store.updateInventory(baseURL: baseURL, token: studioToken) { client in
                                    try await client.createInventoryCategory(request)
                                }
                            },
                            onCreateItem: { request in
                                await store.updateInventory(baseURL: baseURL, token: studioToken) { client in
                                    try await client.createInventoryItem(request)
                                }
                            },
                            onUpdateItem: { id, request in
                                await store.updateInventory(baseURL: baseURL, token: studioToken) { client in
                                    try await client.updateInventoryItem(id: id, payload: request)
                                }
                            },
                            onAdjustStock: { id, request in
                                await store.updateInventory(baseURL: baseURL, token: studioToken) { client in
                                    try await client.adjustInventoryStock(id: id, payload: request)
                                }
                            },
                            onDeleteItem: { id in
                                await store.updateInventory(baseURL: baseURL, token: studioToken) { client in
                                    try await client.deleteInventoryItem(id: id)
                                }
                            }
                        )
                    } else {
                        StudioInventoryWaiting(accentColor: accentColor)
                    }
                case .team:
                    StudioTeamWaiting(accentColor: accentColor)
                }
            } else {
                StudioEmptyState(isLoading: store.isLoading, accentColor: accentColor)
            }
        }
        .task {
            if store.payload == nil {
                await store.refresh(baseURL: baseURL, token: studioToken)
            }
        }
    }
}

private struct StudioNavigationBar: View {
    @Binding var selectedArea: StudioArea
    @Binding var selectedSalesTab: StudioTab
    @Binding var selectedInventoryTab: StudioInventoryTab
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(StudioArea.allCases) { area in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            selectedArea = area
                        }
                    } label: {
                        Label(area.rawValue, systemImage: selectedArea == area ? "checkmark" : area.icon)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedArea.icon)
                        .font(.system(size: 12, weight: .medium))
                    Text(selectedArea.rawValue.uppercased())
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.7)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppPalette.muted)
                }
                .foregroundStyle(accentColor)
                .frame(width: 148, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(AppPalette.line)
                .frame(width: 1)
                .padding(.vertical, 8)

            switch selectedArea {
            case .sales:
                StudioCompactSalesTabs(selectedTab: $selectedSalesTab, accentColor: accentColor)
            case .inventory:
                StudioCompactInventoryTabs(selectedTab: $selectedInventoryTab, accentColor: accentColor)
            case .team:
                StudioCompactStaticTabs(titles: ["STAFF", "TIME CLOCK", "SHIFTS", "PERFORMANCE"], accentColor: accentColor)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioCompactSalesTabs: View {
    @Binding var selectedTab: StudioTab
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StudioTab.allCases) { tab in
                StudioCompactTabButton(
                    title: tab.rawValue.uppercased(),
                    systemImage: tab.icon,
                    isSelected: selectedTab == tab,
                    accentColor: accentColor
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selectedTab = tab
                    }
                }
            }
        }
    }
}

private struct StudioCompactInventoryTabs: View {
    @Binding var selectedTab: StudioInventoryTab
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StudioInventoryTab.essentialsCases) { tab in
                StudioCompactTabButton(
                    title: tab.rawValue.uppercased(),
                    systemImage: tab.icon,
                    isSelected: selectedTab == tab,
                    accentColor: accentColor
                ) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selectedTab = tab
                    }
                }
            }
        }
    }
}

private struct StudioCompactStaticTabs: View {
    let titles: [String]
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(titles, id: \.self) { title in
                StudioCompactTabButton(
                    title: title,
                    systemImage: nil,
                    isSelected: title == titles.first,
                    accentColor: accentColor,
                    action: {}
                )
            }
        }
    }
}

private struct StudioCompactTabButton: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(GlacialFont.caption2(.medium))
                    .tracking(1.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(isSelected ? accentColor : AppPalette.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(isSelected ? accentColor.opacity(0.075) : .clear)
        }
        .buttonStyle(.plain)
    }
}

private struct StudioHero: View {
    let title: String
    let subtitle: String
    let isConnected: Bool
    let isLoading: Bool
    let accentColor: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("EMBEROS STUDIO")
                    .font(GlacialFont.caption(.bold))
                    .tracking(2.4)
                    .foregroundStyle(accentColor)

                Text(title)
                    .font(GlacialFont.largeTitle(.regular))
                    .foregroundStyle(AppPalette.ink)

                Text(subtitle)
                    .font(GlacialFont.subheadline())
                    .foregroundStyle(AppPalette.muted)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(isConnected ? AppPalette.green : AppPalette.red)
                    .frame(width: 8, height: 8)

                Text(isLoading ? "SYNCING" : (isConnected ? "LIVE" : "OFFLINE"))
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.ink)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
        }
    }
}

private struct StudioPeriodBar: View {
    @Binding var selectedPeriod: String
    let options: [(String, String)]
    let accentColor: Color
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selectedPeriod = value
                    onChange()
                } label: {
                    Text(label)
                        .font(GlacialFont.caption(.bold))
                        .tracking(1.3)
                        .foregroundStyle(selectedPeriod == value ? accentColor : AppPalette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selectedPeriod == value ? accentColor.opacity(0.08) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioInventoryTabBar: View {
    @Binding var selectedTab: StudioInventoryTab
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StudioInventoryTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.icon)
                        Text(tab.rawValue)
                    }
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.1)
                    .foregroundStyle(selectedTab == tab ? accentColor : AppPalette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedTab == tab ? accentColor.opacity(0.08) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioTabBar: View {
    @Binding var selectedTab: StudioTab
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StudioTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.icon)
                        Text(tab.rawValue)
                    }
                    .font(GlacialFont.caption(.bold))
                    .tracking(1.1)
                    .foregroundStyle(selectedTab == tab ? accentColor : AppPalette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedTab == tab ? accentColor.opacity(0.08) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioContent: View {
    let payload: StudioSalesPayload
    let selectedPeriod: String
    let selectedTab: StudioTab
    let compareProductA: String
    let compareProductB: String
    let compareMetric: String
    let accentColor: Color
    let onCompareChange: (String, String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioKPIBand(summary: payload.summary, period: payload.period, accentColor: accentColor)

            switch selectedTab {
            case .overview:
                StudioOverviewPanel(payload: payload, selectedPeriod: selectedPeriod, accentColor: accentColor)
            case .reports:
                StudioReportsPanel(groups: payload.reports.groups, accentColor: accentColor)
            case .payments:
                StudioPaymentsPanel(payments: payload.payments, accentColor: accentColor)
            case .trends:
                StudioTrendsPanel(trends: payload.trends, accentColor: accentColor)
            case .compare:
                StudioComparePanel(
                    compare: payload.compare,
                    selectedProductA: compareProductA,
                    selectedProductB: compareProductB,
                    selectedMetric: compareMetric,
                    accentColor: accentColor,
                    onChange: onCompareChange
                )
            }
        }
    }
}

private struct StudioInventoryContent: View {
    let payload: StudioInventoryPayload
    let selectedTab: StudioInventoryTab
    let accentColor: Color
    let onCreateCategory: (StudioInventoryCategoryRequest) async -> Void
    let onCreateItem: (StudioInventoryItemRequest) async -> Void
    let onUpdateItem: (Int, StudioInventoryItemRequest) async -> Void
    let onAdjustStock: (Int, StudioInventoryStockRequest) async -> Void
    let onDeleteItem: (Int) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioInventoryKPIBand(mode: selectedTab, items: selectedTab == .ingredients ? payload.ingredients : payload.products, accentColor: accentColor)

            switch selectedTab {
            case .products:
                StudioInventoryItemsPanel(title: "Products", mode: .products, kicker: "\(payload.products.count) items", items: payload.products, valueMode: .price, accentColor: accentColor, onCreateCategory: onCreateCategory, onCreateItem: onCreateItem, onUpdateItem: onUpdateItem, onAdjustStock: onAdjustStock, onDeleteItem: onDeleteItem)
            case .ingredients:
                StudioInventoryItemsPanel(title: "Ingredients", mode: .ingredients, kicker: "\(payload.ingredients.count) items", items: payload.ingredients, valueMode: .cost, accentColor: accentColor, onCreateCategory: onCreateCategory, onCreateItem: onCreateItem, onUpdateItem: onUpdateItem, onAdjustStock: onAdjustStock, onDeleteItem: onDeleteItem)
            case .recipeLab:
                StudioRecipeLabPanel(accentColor: accentColor)
            case .planning:
                StudioInventoryPlanningPanel(rows: payload.planning, movements: payload.movements, accentColor: accentColor)
            }
        }
    }
}

private struct StudioInventoryKPIBand: View {
    let mode: StudioInventoryTab
    let items: [StudioInventoryItem]
    let accentColor: Color

    private var total: Int {
        items.count
    }

    private var lowStock: Int {
        items.filter { $0.currentStock > 0 && $0.minimumStock > 0 && $0.currentStock <= $0.minimumStock }.count
    }

    private var outOfStock: Int {
        items.filter { $0.currentStock <= 0 }.count
    }

    private var inventoryValue: Double {
        items.reduce(0) { $0 + ($1.currentStock * $1.costPerUnit) }
    }

    private var totalLabel: String {
        mode == .ingredients ? "Total Ingredients" : "Total Products"
    }

    private var totalIcon: String {
        mode == .ingredients ? "shippingbox" : "takeoutbag.and.cup.and.straw"
    }

    var body: some View {
        HStack(spacing: 0) {
            StudioEssentialsSummaryColumn(label: totalLabel, value: "\(total)", note: "Visible in this view", icon: totalIcon, accentColor: accentColor)
            StudioEssentialsDivider()
            StudioEssentialsSummaryColumn(label: "Low Stock", value: "\(lowStock)", note: "Need attention", icon: "exclamationmark.circle", accentColor: accentColor)
            StudioEssentialsDivider()
            StudioEssentialsSummaryColumn(label: "Out of Stock", value: "\(outOfStock)", note: "Restock needed", icon: "minus.circle", accentColor: accentColor)
            StudioEssentialsDivider()
            StudioEssentialsSummaryColumn(label: "Inventory Value", value: money(inventoryValue), note: "Based on current cost", icon: "dollarsign.circle", accentColor: accentColor)
        }
        .frame(minHeight: 112)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppPalette.line)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.line)
                .frame(height: 1)
        }
    }
}

private struct StudioEssentialsSummaryColumn: View {
    let label: String
    let value: String
    let note: String
    let icon: String
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased())
                    .font(GlacialFont.custom(10, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(AppPalette.orange)
                    .lineLimit(1)

                Text(value)
                    .font(GlacialFont.custom(22, .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.top, 12)

                Text(note)
                    .font(GlacialFont.custom(12, .regular))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                    .padding(.top, 8)
            }

            Spacer(minLength: 8)

            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color(red: 0.467, green: 0.443, blue: 0.420))
                .frame(width: 26, height: 26)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct StudioEssentialsDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.line)
            .frame(width: 1)
            .padding(.vertical, 0)
    }
}

private enum StudioInventoryValueMode {
    case price
    case cost
}

private struct StudioInventoryItemsPanel: View {
    let title: String
    let mode: StudioInventoryTab
    let kicker: String
    let items: [StudioInventoryItem]
    let valueMode: StudioInventoryValueMode
    let accentColor: Color
    let onCreateCategory: (StudioInventoryCategoryRequest) async -> Void
    let onCreateItem: (StudioInventoryItemRequest) async -> Void
    let onUpdateItem: (Int, StudioInventoryItemRequest) async -> Void
    let onAdjustStock: (Int, StudioInventoryStockRequest) async -> Void
    let onDeleteItem: (Int) async -> Void
    @State private var selectedItemID: Int?
    @State private var selectedCategory = ""
    @State private var activeSheet: StudioInventorySheet?

    private var categoryNames: [String] {
        Dictionary(grouping: items, by: \.category)
            .map { $0.key }
            .sorted()
    }

    private var visibleItems: [StudioInventoryItem] {
        guard let activeCategory = selectedCategory.isEmpty ? categoryNames.first : selectedCategory else {
            return items
        }

        return items.filter { $0.category == activeCategory }
    }

    private var selectedItem: StudioInventoryItem? {
        guard !visibleItems.isEmpty else { return nil }

        if let selectedItemID,
           let item = visibleItems.first(where: { $0.id == selectedItemID }) {
            return item
        }

        return visibleItems.first
    }

    var body: some View {
        StudioPanel(title: title, kicker: kicker) {
            VStack(spacing: 14) {
                StudioInventoryActionStrip(
                    mode: mode,
                    selectedItem: selectedItem,
                    accentColor: accentColor,
                    onAdd: { activeSheet = .item(nil) },
                    onCategory: { activeSheet = .category },
                    onEdit: { item in activeSheet = .item(item) },
                    onStock: { item in activeSheet = .stock(item) },
                    onDelete: { item in activeSheet = .delete(item) }
                )

                if visibleItems.isEmpty {
                    StudioMiniEmpty(message: "No \(title.lowercased()) synced yet.")
                        .frame(height: 180)
                } else {
                    inventoryList
                }
            }
        }
        .onAppear {
            if selectedCategory.isEmpty {
                selectedCategory = categoryNames.first ?? ""
            }

            if selectedItemID == nil {
                selectedItemID = visibleItems.first?.id
            }
        }
        .onChange(of: items.map(\.id)) { _, _ in
            if !categoryNames.contains(selectedCategory) {
                selectedCategory = categoryNames.first ?? ""
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            selectedItemID = visibleItems.first?.id
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .category:
                StudioInventoryCategoryForm(mode: mode, accentColor: accentColor) { request in
                    await onCreateCategory(request)
                    activeSheet = nil
                }
                .presentationDetents([.height(260)])
                .presentationCornerRadius(10)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.white)
            case .item(let item):
                StudioInventoryItemForm(mode: mode, item: item, accentColor: accentColor) { request in
                    if let item {
                        await onUpdateItem(item.id, request)
                    } else {
                        await onCreateItem(request)
                    }
                    activeSheet = nil
                }
                .presentationDetents([.height(336), .large])
                .presentationCornerRadius(10)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.white)
            case .stock(let item):
                StudioInventoryStockForm(item: item, accentColor: accentColor) { request in
                    await onAdjustStock(item.id, request)
                    activeSheet = nil
                }
                .presentationDetents([.height(300)])
                .presentationCornerRadius(10)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.white)
            case .delete(let item):
                StudioInventoryDeleteForm(item: item, accentColor: accentColor) {
                    await onDeleteItem(item.id)
                    activeSheet = nil
                }
                .presentationDetents([.height(240)])
                .presentationCornerRadius(10)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.white)
            case .detail(let item):
                StudioInventoryDetailCard(
                    item: item,
                    valueMode: valueMode,
                    accentColor: accentColor,
                    onEdit: { activeSheet = .item(item) },
                    onStock: { activeSheet = .stock(item) },
                    onDelete: { activeSheet = .delete(item) }
                )
                .presentationDetents([.medium])
                .presentationCornerRadius(10)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.white)
            }
        }
    }

    private var inventoryList: some View {
        VStack(spacing: 0) {
            StudioInventoryCategoryTabs(
                items: items,
                selectedCategory: $selectedCategory,
                accentColor: accentColor
            )

            List {
                ForEach(visibleItems) { item in
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                            selectedItemID = item.id
                        }
                        activeSheet = .detail(item)
                    } label: {
                        StudioInventoryItemRow(
                            item: item,
                            valueMode: valueMode,
                            isSelected: selectedItem?.id == item.id,
                            accentColor: accentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.white)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            activeSheet = .delete(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            activeSheet = .item(item)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(accentColor)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: listHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var listHeight: CGFloat {
        let rowHeight: CGFloat = 57
        return min(max(CGFloat(visibleItems.count) * rowHeight, rowHeight), 520)
    }
}

private enum StudioInventorySheet: Identifiable {
    case category
    case item(StudioInventoryItem?)
    case stock(StudioInventoryItem)
    case delete(StudioInventoryItem)
    case detail(StudioInventoryItem)

    var id: String {
        switch self {
        case .category:
            return "category"
        case .item(let item):
            return "item-\(item?.id ?? 0)"
        case .stock(let item):
            return "stock-\(item.id)"
        case .delete(let item):
            return "delete-\(item.id)"
        case .detail(let item):
            return "detail-\(item.id)"
        }
    }
}

private struct StudioInventoryActionStrip: View {
    let mode: StudioInventoryTab
    let selectedItem: StudioInventoryItem?
    let accentColor: Color
    let onAdd: () -> Void
    let onCategory: () -> Void
    let onEdit: (StudioInventoryItem) -> Void
    let onStock: (StudioInventoryItem) -> Void
    let onDelete: (StudioInventoryItem) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAdd) {
                Label(mode == .ingredients ? "ADD INGREDIENT" : "ADD PRODUCT", systemImage: "plus")
            }
            .buttonStyle(StudioInventoryActionButtonStyle(accentColor: accentColor, isPrimary: true))

            Button(action: onCategory) {
                Label("CATEGORY", systemImage: "folder.badge.plus")
            }
            .buttonStyle(StudioInventoryActionButtonStyle(accentColor: accentColor, isPrimary: false))

            Spacer(minLength: 8)

            if let selectedItem {
                Button { onStock(selectedItem) } label: {
                    Image(systemName: "plus.forwardslash.minus")
                }
                .buttonStyle(StudioInventoryIconButtonStyle(accentColor: accentColor))

                Button { onEdit(selectedItem) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(StudioInventoryIconButtonStyle(accentColor: accentColor))

                Button { onDelete(selectedItem) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(StudioInventoryIconButtonStyle(accentColor: AppPalette.red))
            }
        }
    }
}

private struct StudioInventoryActionButtonStyle: ButtonStyle {
    let accentColor: Color
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GlacialFont.caption2(.medium))
            .tracking(1.7)
            .foregroundStyle(isPrimary ? .white : accentColor)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(isPrimary ? accentColor : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isPrimary ? accentColor : AppPalette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct StudioInventoryIconButtonStyle: ButtonStyle {
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(accentColor)
            .frame(width: 34, height: 34)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct StudioInventoryCategoryForm: View {
    let mode: StudioInventoryTab
    let accentColor: Color
    let onSave: (StudioInventoryCategoryRequest) async -> Void
    @State private var name = ""

    var body: some View {
        StudioFormShell(title: "New Category", kicker: mode == .ingredients ? "Ingredients" : "Products") {
            StudioFormField(title: "Name", text: $name)
            StudioFormPrimaryButton(title: "CREATE", accentColor: accentColor) {
                let request = StudioInventoryCategoryRequest(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: mode == .ingredients ? "ingredient" : "product"
                )
                await onSave(request)
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct StudioInventoryItemForm: View {
    let mode: StudioInventoryTab
    let item: StudioInventoryItem?
    let accentColor: Color
    let onSave: (StudioInventoryItemRequest) async -> Void
    @State private var name: String
    @State private var sku: String
    @State private var unit: String
    @State private var currentStock: String
    @State private var minimumStock: String
    @State private var cost: String
    @State private var price: String
    @State private var category: String
    @State private var description: String
    @State private var itemType: String
    @State private var linkToPOS: Bool

    init(mode: StudioInventoryTab, item: StudioInventoryItem?, accentColor: Color, onSave: @escaping (StudioInventoryItemRequest) async -> Void) {
        self.mode = mode
        self.item = item
        self.accentColor = accentColor
        self.onSave = onSave
        _name = State(initialValue: item?.name ?? "")
        _sku = State(initialValue: "")
        _unit = State(initialValue: item?.unit ?? (mode == .ingredients ? "g" : "unit"))
        _currentStock = State(initialValue: item.map { cleanNumber($0.currentStock) } ?? "0")
        _minimumStock = State(initialValue: item.map { cleanNumber($0.minimumStock) } ?? "0")
        _cost = State(initialValue: item.map { cleanNumber($0.costPerUnit) } ?? "0")
        _price = State(initialValue: item.map { cleanNumber($0.sellingPrice) } ?? "0")
        _category = State(initialValue: item?.category == "Uncategorized" ? "" : (item?.category ?? ""))
        _description = State(initialValue: "")
        _itemType = State(initialValue: item?.type ?? (mode == .ingredients ? "raw" : "product"))
        _linkToPOS = State(initialValue: item?.linkedToPOS ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(item == nil ? "NEW \(mode == .ingredients ? "INGREDIENT" : "PRODUCT")" : "EDIT \(mode == .ingredients ? "INGREDIENT" : "PRODUCT")")
                .font(GlacialFont.custom(15.5, .regular))
                .tracking(2.0)
                .foregroundStyle(AppPalette.ink)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 14)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                StudioFormField(title: "Name", text: $name)
                StudioFormField(title: "Category", text: $category)
                StudioFormField(title: "Unit", text: $unit)
                StudioFormField(title: "SKU", text: $sku)
                StudioFormField(title: "Current Stock", text: $currentStock, keyboard: .decimalPad)
                StudioFormField(title: "Minimum Stock", text: $minimumStock, keyboard: .decimalPad)
                StudioFormField(title: "Cost", text: $cost, keyboard: .decimalPad)
                if mode == .products {
                    StudioFormField(title: "Price", text: $price, keyboard: .decimalPad)
                } else {
                    StudioFormField(title: "Type", text: $itemType)
                }
            }

            Toggle(isOn: $linkToPOS) {
                Text("LINK TO POS")
                    .font(GlacialFont.custom(10.5, .medium))
                    .tracking(2.4)
                    .foregroundStyle(AppPalette.ink)
            }
            .toggleStyle(.switch)

            StudioFormField(title: "Description", text: $description)

            Spacer(minLength: 0)

            StudioFormPrimaryButton(title: "SAVE", accentColor: accentColor) {
                await onSave(request)
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.ignoresSafeArea())
    }

    private var request: StudioInventoryItemRequest {
        StudioInventoryItemRequest(
            mode: mode == .ingredients ? "ingredients" : "products",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            sku: sku.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sku,
            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unit" : unit,
            currentStock: parseDouble(currentStock),
            minimumStock: parseDouble(minimumStock),
            type: mode == .ingredients ? itemType.lowercased() : "product",
            costPerUnit: parseDouble(cost),
            sellingPrice: mode == .products ? parseDouble(price) : 0,
            linkToPOS: linkToPOS,
            inventoryCategory: category.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
        )
    }
}

private struct StudioInventoryStockForm: View {
    let item: StudioInventoryItem
    let accentColor: Color
    let onSave: (StudioInventoryStockRequest) async -> Void
    @State private var direction = "add"
    @State private var amount = ""

    var body: some View {
        StudioFormShell(title: "Adjust Stock", kicker: item.name) {
            Picker("", selection: $direction) {
                Text("ADD").tag("add")
                Text("USE").tag("use")
            }
            .pickerStyle(.segmented)

            StudioFormField(title: "Amount", text: $amount, keyboard: .decimalPad)

            StudioFormPrimaryButton(title: "APPLY", accentColor: accentColor) {
                await onSave(StudioInventoryStockRequest(direction: direction, amount: parseDouble(amount)))
            }
            .disabled(parseDouble(amount) <= 0)
        }
    }
}

private struct StudioInventoryDeleteForm: View {
    let item: StudioInventoryItem
    let accentColor: Color
    let onDelete: () async -> Void

    var body: some View {
        StudioFormShell(title: "Delete Item", kicker: "Essentials") {
            Text(item.name)
                .font(GlacialFont.title3(.regular))
                .foregroundStyle(AppPalette.ink)
            Text("This removes the item from Essentials. Items used in recipes cannot be deleted.")
                .font(GlacialFont.subheadline())
                .foregroundStyle(AppPalette.muted)

            StudioFormPrimaryButton(title: "DELETE", accentColor: AppPalette.red) {
                await onDelete()
            }
        }
    }
}

private struct StudioFormShell<Content: View>: View {
    let title: String
    let kicker: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker.uppercased())
                    .font(GlacialFont.custom(9, .medium))
                    .tracking(2.4)
                    .foregroundStyle(AppPalette.orange.opacity(0.82))
                Text(title.uppercased())
                    .font(GlacialFont.custom(15.5, .regular))
                    .tracking(1.4)
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white.ignoresSafeArea())
    }
}

private struct StudioFormField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    private var uppercaseText: Binding<String> {
        Binding(
            get: { text.uppercased() },
            set: { text = $0.uppercased() }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(GlacialFont.custom(9, .medium))
                .tracking(2.2)
                .foregroundStyle(AppPalette.muted)
            TextField(title.uppercased(), text: uppercaseText)
                .font(GlacialFont.custom(13, .regular))
                .tracking(1.8)
                .keyboardType(keyboard)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .frame(height: 28)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AppPalette.line)
                        .frame(height: 1)
                }
        }
    }
}

private struct StudioFormPrimaryButton: View {
    let title: String
    let accentColor: Color
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(GlacialFont.custom(10.5, .bold))
                .tracking(2.8)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(accentColor, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct StudioInventoryItemRow: View {
    let item: StudioInventoryItem
    let valueMode: StudioInventoryValueMode
    let isSelected: Bool
    let accentColor: Color

    private var value: String {
        switch valueMode {
        case .price:
            return item.sellingPrice > 0 ? money(item.sellingPrice) : formatQuantity(item.currentStock, unit: item.unit)
        case .cost:
            return item.costPerUnit > 0 ? money(item.costPerUnit) : formatQuantity(item.currentStock, unit: item.unit)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            StudioInventoryItemMark(item: item, accentColor: accentColor)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name.uppercased())
                    .font(GlacialFont.custom(12.5, isSelected ? .semibold : .medium))
                    .tracking(1.6)
                    .foregroundStyle(isSelected ? AppPalette.ink : AppPalette.ink.opacity(0.86))
                    .lineLimit(1)
                Text("\(item.category.uppercased())  ·  \(formatQuantity(item.currentStock, unit: item.unit))")
                    .font(GlacialFont.caption2())
                    .tracking(1.3)
                    .foregroundStyle(item.isLowStock ? AppPalette.red : AppPalette.muted)
                    .lineLimit(1)
            }

            Spacer()

            Text(value.uppercased())
                .font(GlacialFont.caption(.medium))
                .tracking(1.2)
                .monospacedDigit()
                .foregroundStyle(isSelected ? accentColor : AppPalette.ink)
                .lineLimit(1)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .background(isSelected ? accentColor.opacity(0.055) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.line)
                .frame(height: 1)
        }
    }
}

private struct StudioInventoryItemMark: View {
    let item: StudioInventoryItem
    let accentColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(item.isLowStock ? AppPalette.red.opacity(0.08) : AppPalette.background)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppPalette.line, lineWidth: 1))

            if let imageURL = item.imageURL,
               let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        inventoryIcon
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                inventoryIcon
            }
        }
    }

    private var inventoryIcon: some View {
        Image(systemName: item.type == "product" ? "takeoutbag.and.cup.and.straw" : "leaf")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(item.isLowStock ? AppPalette.red : accentColor)
    }
}

private struct StudioInventoryCategoryTabs: View {
    let items: [StudioInventoryItem]
    @Binding var selectedCategory: String
    let accentColor: Color

    private var categories: [String] {
        Dictionary(grouping: items, by: \.category)
            .map { $0.key }
            .sorted()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.self) { category in
                    StudioInventoryCategoryPill(title: category, isSelected: selectedCategory == category, accentColor: accentColor) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 1)
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.line)
                .frame(height: 1)
        }
        .onAppear {
            if selectedCategory.isEmpty {
                selectedCategory = categories.first ?? ""
            }
        }
    }
}

private struct StudioInventoryCategoryPill: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(GlacialFont.caption(.medium))
                .tracking(1.6)
                .foregroundStyle(isSelected ? accentColor : AppPalette.muted)
                .lineLimit(1)
                .padding(.horizontal, 15)
                .frame(height: 38)
                .background(isSelected ? accentColor.opacity(0.08) : Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? accentColor.opacity(0.24) : AppPalette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct StudioInventoryDetailCard: View {
    let item: StudioInventoryItem
    let valueMode: StudioInventoryValueMode
    let accentColor: Color
    let onEdit: () -> Void
    let onStock: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioInventoryItemInspector(item: item, valueMode: valueMode, accentColor: accentColor)

            HStack(spacing: 10) {
                Button(action: onStock) {
                    Label("STOCK", systemImage: "plus.forwardslash.minus")
                }
                .buttonStyle(StudioInventorySheetActionStyle(accentColor: accentColor, role: .secondary))

                Button(action: onEdit) {
                    Label("EDIT", systemImage: "pencil")
                }
                .buttonStyle(StudioInventorySheetActionStyle(accentColor: accentColor, role: .primary))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(StudioInventorySheetIconStyle(accentColor: AppPalette.red))
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white.ignoresSafeArea())
    }
}

private enum StudioInventorySheetActionRole {
    case primary
    case secondary
}

private struct StudioInventorySheetActionStyle: ButtonStyle {
    let accentColor: Color
    let role: StudioInventorySheetActionRole

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GlacialFont.custom(12.5, .medium))
            .tracking(2.1)
            .foregroundStyle(role == .primary ? .white : accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(role == .primary ? accentColor : accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct StudioInventorySheetIconStyle: ButtonStyle {
    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(accentColor)
            .frame(width: 42, height: 42)
            .background(accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct StudioInventoryItemInspector: View {
    let item: StudioInventoryItem
    let valueMode: StudioInventoryValueMode
    let accentColor: Color

    private var primaryValue: String {
        switch valueMode {
        case .price:
            return item.sellingPrice > 0 ? money(item.sellingPrice).uppercased() : "NO PRICE"
        case .cost:
            return item.costPerUnit > 0 ? money(item.costPerUnit).uppercased() : "NO COST"
        }
    }

    private var stockRatio: Double {
        guard item.minimumStock > 0 else { return 1 }
        return min(max(item.currentStock / item.minimumStock, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                StudioInventoryItemMark(item: item, accentColor: accentColor)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.category.uppercased())
                        .font(GlacialFont.custom(10.5, .medium))
                        .tracking(2.6)
                        .foregroundStyle(AppPalette.orange.opacity(0.82))
                    Text(item.name.uppercased())
                        .font(GlacialFont.custom(19, .regular))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            VStack(spacing: 0) {
                StudioInventoryCompactMetricLine(label: valueMode == .price ? "Price" : "Cost", value: primaryValue)
                StudioInventoryCompactMetricLine(label: "Current", value: formatQuantity(item.currentStock, unit: item.unit).uppercased())
                StudioInventoryCompactMetricLine(label: "Minimum", value: formatQuantity(item.minimumStock, unit: item.unit).uppercased())
                StudioInventoryCompactMetricLine(label: "Type", value: item.type.uppercased())
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.isLowStock ? "LOW STOCK" : "STOCK LEVEL")
                        .font(GlacialFont.custom(10.5, .medium))
                        .tracking(2.5)
                        .foregroundStyle(item.isLowStock ? AppPalette.red : AppPalette.muted)
                    Spacer()
                    Text(item.minimumStock > 0 ? "\(Int(stockRatio * 100))%" : "TRACKED")
                        .font(GlacialFont.custom(10.5, .medium))
                        .tracking(2.0)
                        .foregroundStyle(AppPalette.muted)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(AppPalette.line.opacity(0.72))
                        Rectangle()
                            .fill(item.isLowStock ? AppPalette.red : accentColor)
                            .frame(width: max(6, proxy.size.width * stockRatio))
                    }
                }
                .frame(height: 5)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct StudioRecipeLabPanel: View {
    let accentColor: Color
    @State private var recipeName = "PROTEIN OATS - DAILY GO"
    @State private var category = "PROTEIN OATS"
    @State private var servingSize = "350 G"
    @State private var recipeYield = "1"
    @State private var version = "1.0 TEST"
    @State private var sellingPrice = "65000"
    @State private var ingredients: [StudioLabIngredient] = StudioLabIngredient.sample

    private var metrics: StudioLabMetrics {
        StudioLabMetrics(ingredients: ingredients, sellingPrice: parseDouble(sellingPrice))
    }

    private var sortedIngredients: [StudioLabIngredient] {
        ingredients.sorted { $0.lineCost > $1.lineCost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioRecipeFieldStrip(
                recipeName: $recipeName,
                category: $category,
                servingSize: $servingSize,
                recipeYield: $recipeYield,
                version: $version
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    builderPanel
                    pricingPanel.frame(width: 300)
                    insightsPanel.frame(width: 280)
                }

                VStack(alignment: .leading, spacing: 14) {
                    builderPanel
                    HStack(alignment: .top, spacing: 14) {
                        pricingPanel
                        insightsPanel
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    alternativesPanel
                    breakdownPanel.frame(width: 330)
                }

                VStack(alignment: .leading, spacing: 14) {
                    alternativesPanel
                    breakdownPanel
                }
            }

            Text("SANDBOX ENVIRONMENT. CHANGES STAY INSIDE STUDIO AND DO NOT TOUCH LIVE INVENTORY, STOCK, POS OR RECIPES.")
                .font(GlacialFont.custom(9.5, .regular))
                .tracking(2.0)
                .foregroundStyle(AppPalette.muted)
        }
    }

    private var builderPanel: some View {
        StudioPanel(title: "Recipe Builder", kicker: "1. Builder") {
            VStack(spacing: 12) {
                HStack {
                    Text("CREATE A VIRTUAL RECIPE")
                        .font(GlacialFont.custom(9.5, .medium))
                        .tracking(2.3)
                        .foregroundStyle(AppPalette.muted)
                    Spacer()
                    Button {
                        ingredients.append(.blank)
                    } label: {
                        Label("ADD INGREDIENT", systemImage: "plus")
                    }
                    .buttonStyle(StudioInventoryActionButtonStyle(accentColor: accentColor, isPrimary: false))
                }

                VStack(spacing: 0) {
                    StudioRecipeBuilderHeader()
                    ForEach($ingredients) { $ingredient in
                        StudioRecipeIngredientRow(ingredient: $ingredient) {
                            ingredients.removeAll { $0.id == ingredient.id }
                            if ingredients.isEmpty {
                                ingredients.append(.blank)
                            }
                        }
                    }
                }

                StudioInventoryCompactMetricLine(label: "Total Recipe Cost", value: money(metrics.recipeCost).uppercased())
            }
        }
    }

    private var pricingPanel: some View {
        StudioPanel(title: "Cost & Margin", kicker: "2. Pricing") {
            VStack(alignment: .leading, spacing: 14) {
                StudioFormField(title: "Selling Price", text: $sellingPrice, keyboard: .decimalPad)

                StudioMarginPieChart(costFraction: metrics.foodCostFraction, marginPercent: metrics.grossMargin, accentColor: accentColor)
                    .frame(height: 174)

                VStack(spacing: 0) {
                    StudioInventoryCompactMetricLine(label: "Recipe Cost", value: money(metrics.recipeCost).uppercased())
                    StudioInventoryCompactMetricLine(label: "Gross Profit", value: money(metrics.grossProfit).uppercased())
                    StudioInventoryCompactMetricLine(label: "Gross Margin", value: String(format: "%.1f%%", metrics.grossMargin).uppercased())
                    StudioInventoryCompactMetricLine(label: "Food Cost", value: String(format: "%.1f%%", metrics.foodCost).uppercased())
                    StudioInventoryCompactMetricLine(label: "Monthly Profit", value: money(metrics.grossProfit * 300).uppercased())
                }
            }
        }
    }

    private var insightsPanel: some View {
        StudioPanel(title: "AI Insights", kicker: "3. Signals") {
            VStack(spacing: 10) {
                ForEach(StudioLabInsight.make(from: metrics, ingredients: sortedIngredients)) { insight in
                    StudioRecipeInsightCard(insight: insight, accentColor: accentColor)
                }
            }
        }
    }

    private var alternativesPanel: some View {
        StudioPanel(title: "Recipe Alternatives", kicker: "Sandbox ideas") {
            HStack(alignment: .top, spacing: 12) {
                StudioRecipeAlternativeCard(
                    title: "Alternative 1",
                    lines: ["REDUCE HONEY BY 3G", "REDUCE GRANOLA BY 5G"],
                    margin: alternativeMargin(cost: max(0, metrics.recipeCost - 1900), price: metrics.sellingPrice),
                    profit: metrics.sellingPrice - max(0, metrics.recipeCost - 1900),
                    accentColor: accentColor
                ) {
                    applyIngredientDelta(nameContains: "HONEY", amount: -3)
                    applyIngredientDelta(nameContains: "GRANOLA", amount: -5)
                }

                StudioRecipeAlternativeCard(
                    title: "Alternative 2",
                    lines: ["INCREASE PRICE TO 68,000 VND", "KEEP RECIPE UNCHANGED"],
                    margin: alternativeMargin(cost: metrics.recipeCost, price: max(metrics.sellingPrice, 68000)),
                    profit: max(metrics.sellingPrice, 68000) - metrics.recipeCost,
                    accentColor: accentColor
                ) {
                    sellingPrice = cleanNumber(max(metrics.sellingPrice, 68000))
                }

                StudioRecipeAlternativeCard(
                    title: "Alternative 3",
                    lines: ["REDUCE BLUEBERRIES BY 10G", "INCREASE YOGURT BY 10G"],
                    margin: alternativeMargin(cost: max(0, metrics.recipeCost - 600), price: metrics.sellingPrice),
                    profit: metrics.sellingPrice - max(0, metrics.recipeCost - 600),
                    accentColor: accentColor
                ) {
                    applyIngredientDelta(nameContains: "BLUEBERR", amount: -10)
                    applyIngredientDelta(nameContains: "YOGURT", amount: 10)
                }
            }
        }
    }

    private var breakdownPanel: some View {
        StudioPanel(title: "Cost Breakdown", kicker: "Ingredient share") {
            HStack(alignment: .center, spacing: 18) {
                StudioCostBreakdownPie(ingredients: sortedIngredients, totalCost: metrics.recipeCost, accentColor: accentColor)
                    .frame(width: 124, height: 124)

                VStack(spacing: 0) {
                    ForEach(Array(sortedIngredients.prefix(6))) { ingredient in
                        StudioInventoryCompactMetricLine(
                            label: ingredient.name.isEmpty ? "Ingredient" : ingredient.name,
                            value: metrics.recipeCost > 0 ? String(format: "%.1f%%", ingredient.lineCost / metrics.recipeCost * 100) : "0%"
                        )
                    }
                }
            }
        }
    }

    private func alternativeMargin(cost: Double, price: Double) -> Double {
        price > 0 ? ((price - cost) / price) * 100 : 0
    }

    private func applyIngredientDelta(nameContains needle: String, amount: Double) {
        ingredients = ingredients.map { ingredient in
            guard ingredient.name.uppercased().contains(needle) else {
                return ingredient
            }

            var copy = ingredient
            copy.quantity = cleanNumber(max(0, ingredient.quantityValue + amount))
            return copy
        }
    }
}

private struct StudioLabIngredient: Identifiable {
    let id: UUID
    var name: String
    var quantity: String
    var unit: String
    var unitCost: String

    var quantityValue: Double { parseDouble(quantity) }
    var unitCostValue: Double { parseDouble(unitCost) }
    var lineCost: Double { quantityValue * unitCostValue }

    static var blank: StudioLabIngredient {
        StudioLabIngredient(id: UUID(), name: "NEW INGREDIENT", quantity: "10", unit: "G", unitCost: "100")
    }

    static var sample: [StudioLabIngredient] {
        [
            StudioLabIngredient(id: UUID(), name: "ROLLED OATS", quantity: "50", unit: "G", unitCost: "45"),
            StudioLabIngredient(id: UUID(), name: "WHEY PROTEIN", quantity: "25", unit: "G", unitCost: "150"),
            StudioLabIngredient(id: UUID(), name: "GREEK YOGURT", quantity: "100", unit: "G", unitCost: "120"),
            StudioLabIngredient(id: UUID(), name: "BLUEBERRIES", quantity: "50", unit: "G", unitCost: "180"),
            StudioLabIngredient(id: UUID(), name: "HONEY", quantity: "10", unit: "G", unitCost: "80"),
            StudioLabIngredient(id: UUID(), name: "GRANOLA", quantity: "20", unit: "G", unitCost: "140"),
        ]
    }
}

private struct StudioLabMetrics {
    let ingredients: [StudioLabIngredient]
    let sellingPrice: Double

    var recipeCost: Double {
        ingredients.reduce(0) { $0 + $1.lineCost }
    }

    var grossProfit: Double {
        sellingPrice - recipeCost
    }

    var grossMargin: Double {
        sellingPrice > 0 ? (grossProfit / sellingPrice) * 100 : 0
    }

    var foodCost: Double {
        sellingPrice > 0 ? (recipeCost / sellingPrice) * 100 : 0
    }

    var foodCostFraction: Double {
        sellingPrice > 0 ? min(max(recipeCost / sellingPrice, 0), 1) : 0
    }
}

private struct StudioLabInsight: Identifiable {
    let id = UUID()
    let tone: StudioLabInsightTone
    let icon: String
    let title: String
    let body: String

    static func make(from metrics: StudioLabMetrics, ingredients: [StudioLabIngredient]) -> [StudioLabInsight] {
        let top = ingredients.first
        let topShare = metrics.recipeCost > 0 ? (top?.lineCost ?? 0) / metrics.recipeCost * 100 : 0
        let marginTone: StudioLabInsightTone = metrics.grossMargin >= 50 ? .good : (metrics.grossMargin >= 35 ? .medium : .poor)
        let marginTitle = metrics.grossMargin >= 50
            ? "CURRENT GROSS MARGIN IS HEALTHY"
            : (metrics.grossMargin >= 35 ? "CURRENT MARGIN CAN IMPROVE" : "CURRENT PRICE LOOKS LOW")
        let targetPrice = metrics.recipeCost > 0 ? ceil((metrics.recipeCost / 0.48) / 1000) * 1000 : 0
        let saver = ingredients.first { $0.quantityValue >= 10 && $0.unitCostValue > 0 }
        let saving = (saver?.unitCostValue ?? 0) * min(3, saver?.quantityValue ?? 0)

        return [
            StudioLabInsight(tone: marginTone, icon: "activity", title: marginTitle, body: "MARGIN \(String(format: "%.1f", metrics.grossMargin))% · FOOD COST \(String(format: "%.1f", metrics.foodCost))%"),
            StudioLabInsight(tone: .medium, icon: "chart.bar", title: "\(top?.name.uppercased() ?? "INGREDIENT") IS THE LARGEST COST", body: "IT REPRESENTS \(String(format: "%.1f", topShare))% OF TOTAL RECIPE COST."),
            StudioLabInsight(tone: targetPrice > metrics.sellingPrice ? .medium : .good, icon: "arrow.up.right", title: "TARGET MARGIN CHECK", body: targetPrice > metrics.sellingPrice ? "TRY AROUND \(money(targetPrice).uppercased()) FOR 52% MARGIN." : "CURRENT PRICE IS ABOVE THE 52% TARGET ESTIMATE."),
            StudioLabInsight(tone: .good, icon: "minus", title: saver.map { "SMALL REDUCTION: \($0.name.uppercased())" } ?? "NO REDUCTION SIGNAL YET", body: saver.map { "REDUCE UP TO 3 \($0.unit.uppercased()) TO SAVE ABOUT \(money(saving).uppercased())." } ?? "ADD MORE INGREDIENT QUANTITIES TO GENERATE IDEAS."),
        ]
    }
}

private enum StudioLabInsightTone {
    case good
    case medium
    case poor
}

private struct StudioRecipeFieldStrip: View {
    @Binding var recipeName: String
    @Binding var category: String
    @Binding var servingSize: String
    @Binding var recipeYield: String
    @Binding var version: String

    var body: some View {
        HStack(spacing: 0) {
            StudioRecipeStripField(title: "Recipe Name", text: $recipeName)
            StudioEssentialsDivider()
            StudioRecipeStripField(title: "Category", text: $category)
            StudioEssentialsDivider()
            StudioRecipeStripField(title: "Serving Size", text: $servingSize)
            StudioEssentialsDivider()
            StudioRecipeStripField(title: "Yield", text: $recipeYield, keyboard: .numberPad)
            StudioEssentialsDivider()
            StudioRecipeStripField(title: "Version", text: $version)
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioRecipeStripField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(GlacialFont.custom(9.5, .medium))
                .tracking(2.2)
                .foregroundStyle(AppPalette.muted)
            TextField(title.uppercased(), text: $text)
                .font(GlacialFont.custom(13, .regular))
                .tracking(1.4)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StudioRecipeBuilderHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("INGREDIENT").frame(maxWidth: .infinity, alignment: .leading)
            Text("QTY").frame(width: 52, alignment: .trailing)
            Text("UNIT").frame(width: 42, alignment: .center)
            Text("VND / UNIT").frame(width: 76, alignment: .trailing)
            Text("COST").frame(width: 88, alignment: .trailing)
            Spacer().frame(width: 34)
        }
        .font(GlacialFont.custom(9, .medium))
        .tracking(1.7)
        .foregroundStyle(AppPalette.muted)
        .padding(.bottom, 7)
    }
}

private struct StudioRecipeIngredientRow: View {
    @Binding var ingredient: StudioLabIngredient
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StudioRecipeInlineField(text: $ingredient.name)
                .frame(maxWidth: .infinity)
            StudioRecipeInlineField(text: $ingredient.quantity, keyboard: .decimalPad, alignment: .trailing)
                .frame(width: 52)
            StudioRecipeInlineField(text: $ingredient.unit, alignment: .center)
                .frame(width: 42)
            StudioRecipeInlineField(text: $ingredient.unitCost, keyboard: .decimalPad, alignment: .trailing)
                .frame(width: 76)
            Text(money(ingredient.lineCost).uppercased())
                .font(GlacialFont.custom(11.5, .medium))
                .tracking(1.0)
                .monospacedDigit()
                .foregroundStyle(AppPalette.ink)
                .frame(width: 88, alignment: .trailing)
            Button(action: onRemove) {
                Image(systemName: "minus")
            }
            .buttonStyle(StudioInventoryIconButtonStyle(accentColor: AppPalette.red))
        }
        .padding(.vertical, 4)
    }
}

private struct StudioRecipeInlineField: View {
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var alignment: TextAlignment = .leading

    var body: some View {
        TextField("", text: uppercaseBinding)
            .font(GlacialFont.custom(12.5, .regular))
            .tracking(1.2)
            .keyboardType(keyboard)
            .multilineTextAlignment(alignment)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
            .frame(height: 34)
            .padding(.horizontal, 8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }

    private var uppercaseBinding: Binding<String> {
        Binding(
            get: { text.uppercased() },
            set: { text = $0.uppercased() }
        )
    }
}

private struct StudioMarginPieChart: View {
    let costFraction: Double
    let marginPercent: Double
    let accentColor: Color

    private var safeCostFraction: Double {
        min(max(costFraction, 0), 1)
    }

    private var marginColor: Color {
        marginPercent >= 50 ? AppPalette.green : (marginPercent >= 35 ? Color(red: 0.78, green: 0.54, blue: 0.27) : AppPalette.red)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.07), radius: 10, x: 0, y: 7)

            Circle()
                .trim(from: 0, to: safeCostFraction)
                .stroke(AppPalette.red.opacity(0.86), style: StrokeStyle(lineWidth: 34, lineCap: .butt))
                .rotationEffect(.degrees(-90))

            Circle()
                .trim(from: safeCostFraction, to: 1)
                .stroke(marginColor, style: StrokeStyle(lineWidth: 34, lineCap: .butt))
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(Color.white)
                .frame(width: 82, height: 82)
                .overlay(Circle().stroke(AppPalette.line, lineWidth: 1))

            VStack(spacing: 3) {
                Text("GROSS MARGIN")
                    .font(GlacialFont.custom(8.5, .medium))
                    .tracking(2.0)
                    .foregroundStyle(AppPalette.muted)
                Text(String(format: "%.1f%%", marginPercent))
                    .font(GlacialFont.custom(20, .medium))
                    .monospacedDigit()
                    .foregroundStyle(marginColor)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StudioRecipeInsightCard: View {
    let insight: StudioLabInsight
    let accentColor: Color

    private var color: Color {
        switch insight.tone {
        case .good:
            return AppPalette.green
        case .medium:
            return Color(red: 0.78, green: 0.54, blue: 0.27)
        case .poor:
            return AppPalette.red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: insight.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .font(GlacialFont.custom(11.5, .medium))
                    .tracking(1.3)
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                Text(insight.body)
                    .font(GlacialFont.custom(10.5, .regular))
                    .tracking(1.1)
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioRecipeAlternativeCard: View {
    let title: String
    let lines: [String]
    let margin: Double
    let profit: Double
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title.uppercased())
                .font(GlacialFont.custom(12, .medium))
                .tracking(1.5)
                .foregroundStyle(AppPalette.ink)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(GlacialFont.custom(10.5, .regular))
                        .tracking(1.1)
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }
            }

            VStack(spacing: 0) {
                StudioInventoryCompactMetricLine(label: "Est. Margin", value: String(format: "%.1f%%", margin))
                StudioInventoryCompactMetricLine(label: "Profit", value: money(profit).uppercased())
            }

            Button(action: action) {
                Text("APPLY TO BUILDER")
            }
            .buttonStyle(StudioInventoryActionButtonStyle(accentColor: accentColor, isPrimary: false))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioCostBreakdownPie: View {
    let ingredients: [StudioLabIngredient]
    let totalCost: Double
    let accentColor: Color

    private let colors: [Color] = [
        AppPalette.green,
        Color(red: 0.42, green: 0.62, blue: 0.82),
        Color(red: 0.78, green: 0.54, blue: 0.27),
        Color(red: 0.56, green: 0.42, blue: 0.78),
        AppPalette.orange,
        AppPalette.red,
    ]

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppPalette.line, lineWidth: 24)

            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(colors[index % colors.count], style: StrokeStyle(lineWidth: 24, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            Circle()
                .fill(Color.white)
                .frame(width: 58, height: 58)
                .overlay(Circle().stroke(AppPalette.line, lineWidth: 1))

            Text("COST")
                .font(GlacialFont.custom(8.5, .medium))
                .tracking(1.9)
                .foregroundStyle(AppPalette.muted)
        }
    }

    private var segments: [(start: Double, end: Double)] {
        guard totalCost > 0 else { return [] }
        var cursor = 0.0
        return ingredients.prefix(6).map { ingredient in
            let start = cursor
            cursor += ingredient.lineCost / totalCost
            return (start, min(cursor, 1))
        }
    }
}

private struct StudioInventoryCompactMetricLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .font(GlacialFont.custom(11, .regular))
                .tracking(2.6)
                .foregroundStyle(AppPalette.muted)
            Spacer()
            Text(value.uppercased())
                .font(GlacialFont.custom(14, .medium))
                .tracking(1.5)
                .monospacedDigit()
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.line)
                .frame(height: 1)
        }
    }
}

private struct StudioInventoryPlanningPanel: View {
    let rows: [StudioInventoryPlanningRow]
    let movements: [StudioInventoryMovement]
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StudioPanel(title: "Planning", kicker: "Buy and produce") {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        StudioFlatRow(
                            title: row.name,
                            meta: "\(row.action.uppercased()) \(formatQuantity(row.suggestedQuantity, unit: row.unit)) · \(row.daysRemaining.map { String(format: "%.1f days left", $0) } ?? "usage unknown")",
                            value: formatQuantity(row.currentStock, unit: row.unit),
                            titleStyle: row.isLowStock ? .reportWeek : .standard
                        )
                    }

                    if rows.isEmpty {
                        StudioMiniEmpty(message: "No inventory action needed.")
                            .frame(height: 118)
                    }
                }
            }

            StudioPanel(title: "Movements", kicker: "Latest changes") {
                VStack(spacing: 0) {
                    ForEach(movements) { movement in
                        StudioFlatRow(
                            title: movement.itemName,
                            meta: movement.type.replacingOccurrences(of: "_", with: " ").uppercased(),
                            value: formatQuantity(movement.quantity, unit: movement.unit),
                            titleStyle: .standard
                        )
                    }

                    if movements.isEmpty {
                        StudioMiniEmpty(message: "No stock movement recorded.")
                            .frame(height: 118)
                    }
                }
            }
        }
    }
}

private struct StudioInventoryWaiting: View {
    let accentColor: Color

    var body: some View {
        StudioPanel(title: "Inventory", kicker: "API waiting") {
            StudioMiniEmpty(message: "Deploy the Studio Inventory API to sync Products, Ingredients, Recipe Lab, and Planning.")
                .frame(height: 150)
        }
    }
}

private struct StudioTeamWaiting: View {
    let accentColor: Color

    var body: some View {
        StudioPanel(title: "Team", kicker: "Next section") {
            StudioMiniEmpty(message: "Team will bring Staff, Time Clock, Shifts, and Performance into Studio.")
                .frame(height: 150)
        }
    }
}

private struct StudioKPIBand: View {
    let summary: StudioSummary
    let period: StudioPeriod
    let accentColor: Color

    var body: some View {
        HStack(spacing: 0) {
            StudioKPIColumn(label: "Revenue", value: money(summary.revenue), note: period.label, icon: "chart.line.uptrend.xyaxis", accentColor: accentColor)
            StudioInlineDivider()
            StudioKPIColumn(label: "Orders", value: "\(summary.orders)", note: "Recorded orders", icon: "receipt", accentColor: accentColor)
            StudioInlineDivider()
            StudioKPIColumn(label: "Average Ticket", value: money(summary.averageTicket), note: "Order value", icon: "waveform.path.ecg", accentColor: accentColor)
            StudioInlineDivider()
            StudioKPIColumn(label: "Best Seller", value: summary.bestSeller?.name ?? "No sales yet", note: summary.bestSeller.map { "\(Int($0.quantity)) sold" } ?? "Waiting", icon: "star", accentColor: accentColor)
        }
        .padding(.vertical, 16)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioKPIColumn: View {
    let label: String
    let value: String
    let note: String
    let icon: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.regular))
                    .foregroundStyle(AppPalette.muted)
                Text(label.uppercased())
                    .font(GlacialFont.caption2())
                    .tracking(2.5)
                    .foregroundStyle(accentColor)
            }

            Text(value)
                .font(GlacialFont.title3(.regular))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(note)
                .font(GlacialFont.caption())
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }
}

private struct StudioInlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppPalette.line)
            .frame(width: 1)
            .padding(.vertical, 4)
    }
}

private struct StudioOverviewPanel: View {
    let payload: StudioSalesPayload
    let selectedPeriod: String
    let accentColor: Color

    private static let apiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayNumberFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EE"
        return formatter
    }()

    private var normalizedSelectedPeriod: String {
        switch selectedPeriod {
        case "day":
            return "today"
        case "week":
            return "this_week"
        case "month":
            return "this_month"
        case "year":
            return "this_year"
        default:
            return selectedPeriod
        }
    }

    private var revenueRows: [StudioRevenueChartPoint] {
        if normalizedSelectedPeriod == "today" {
            return payload.trends.hours
                .filter { hour in
                    let value = Int(hour.hour.prefix(2)) ?? 0
                    return value >= 6 && value <= 20
                }
                .map {
                    StudioRevenueChartPoint(id: $0.hour, label: $0.hour.replacingOccurrences(of: ":00", with: ""), revenue: $0.revenue)
                }
        }

        let limit = normalizedSelectedPeriod == "this_week" ? 7 : 30

        return filledDailyRevenueRows(limit: limit)
    }

    private func filledDailyRevenueRows(limit: Int) -> [StudioRevenueChartPoint] {
        if normalizedSelectedPeriod == "this_week" {
            return fixedRecentDailyRevenueRows(dayCount: 7)
        }

        guard
            let periodStart = Self.apiDateFormatter.date(from: payload.period.startDate),
            let rawPeriodEnd = Self.apiDateFormatter.date(from: payload.period.endDate)
        else {
            return payload.overview.daily.prefix(limit).map {
                StudioRevenueChartPoint(id: $0.date, label: String($0.date.suffix(2)), revenue: $0.revenue)
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let today = calendar.startOfDay(for: Date())
        let periodEnd = min(calendar.startOfDay(for: rawPeriodEnd), today)
        let periodStartDay = calendar.startOfDay(for: periodStart)
        let limitedStart = calendar.date(byAdding: .day, value: -(limit - 1), to: periodEnd) ?? periodEnd
        let chartStart = max(periodStartDay, limitedStart)
        let revenueByDate = Dictionary(uniqueKeysWithValues: payload.overview.daily.map { ($0.date, $0.revenue) })

        var rows: [StudioRevenueChartPoint] = []
        var cursor = chartStart

        while cursor <= periodEnd {
            let key = Self.apiDateFormatter.string(from: cursor)
            rows.append(
                StudioRevenueChartPoint(
                    id: key,
                    label: dailyChartLabel(for: cursor),
                    revenue: revenueByDate[key] ?? 0
                )
            )

            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }

        return rows
    }

    private func fixedRecentDailyRevenueRows(dayCount: Int) -> [StudioRevenueChartPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let today = calendar.startOfDay(for: Date())
        let chartStart = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
        let revenueByDate = Dictionary(uniqueKeysWithValues: payload.overview.daily.map { ($0.date, $0.revenue) })

        var rows: [StudioRevenueChartPoint] = []
        var cursor = chartStart

        while cursor <= today {
            let key = Self.apiDateFormatter.string(from: cursor)
            rows.append(
                StudioRevenueChartPoint(
                    id: key,
                    label: dailyChartLabel(for: cursor),
                    revenue: revenueByDate[key] ?? 0
                )
            )

            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }

        return rows
    }

    private func dailyChartLabel(for date: Date) -> String {
        if normalizedSelectedPeriod == "this_month" || normalizedSelectedPeriod == "this_year" {
            return Self.dayNumberFormatter.string(from: date)
        }

        return Self.weekdayFormatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StudioPanel(title: "Revenue By Day", kicker: payload.period.label) {
                StudioBarChart(rows: revenueRows, accentColor: accentColor)
            }

            StudioPanel(title: "Top Products", kicker: "Quantity sold") {
                StudioRankedRows(rows: payload.overview.topProducts.map {
                    StudioRankedRow(title: $0.name, value: "\(Int($0.quantity))", note: money($0.revenue))
                }, titleStyle: .trackedProduct)
            }
        }
    }
}

private struct StudioReportsPanel: View {
    let groups: [StudioReportGroup]
    let accentColor: Color

    var body: some View {
        StudioPanel(title: "Recorded Sales", kicker: "Weekly recap") {
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    StudioDisclosureRow(title: group.label, meta: "\(group.orders) orders", value: money(group.revenue), rowStyle: .reportWeek) {
                        ForEach(group.days) { day in
                            StudioFlatRow(title: day.label, meta: "\(day.orders) orders", value: money(day.revenue), titleStyle: .reportDay)
                        }
                    }
                }
            }
        }
    }
}

private struct StudioPaymentsPanel: View {
    let payments: StudioPayments
    let accentColor: Color
    @State private var showsHistory = false

    private var canOpenHistory: Bool {
        !payments.history.isEmpty || !payments.rows.isEmpty
    }

    private var historyOrderCount: Int {
        payments.history.reduce(0) { total, group in
            total + group.orders
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StudioPanel(title: "Payment Mix", kicker: money(payments.totalRevenue)) {
                HStack(alignment: .center, spacing: 18) {
                    StudioPaymentPie(metrics: payments.summary, accentColor: accentColor)
                        .frame(width: 132, height: 122)

                    VStack(spacing: 0) {
                        ForEach(Array(payments.summary.enumerated()), id: \.element.id) { index, metric in
                            StudioPaymentMixRow(metric: metric, index: index, accentColor: accentColor)
                        }
                    }
                }
            }

            StudioPanel(title: "Recent Payments", kicker: "Completed orders") {
                VStack(spacing: 0) {
                    ForEach(Array(payments.rows.prefix(10))) { row in
                        StudioFlatRow(title: row.orderNumber, meta: "\(row.methodLabel) · \(row.sourceLabel)", value: money(row.total), titleStyle: .paymentOrder)
                    }

                    if canOpenHistory {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                showsHistory.toggle()
                            }
                        } label: {
                            HStack {
                                Text(showsHistory ? "HIDE HISTORY" : historyButtonTitle)
                                    .font(GlacialFont.caption2(.medium))
                                    .tracking(2.2)
                                    .foregroundStyle(accentColor)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(AppPalette.muted)
                                    .rotationEffect(.degrees(showsHistory ? 180 : 0))
                            }
                            .padding(.top, 12)
                            .padding(.bottom, showsHistory ? 10 : 0)
                        }
                        .buttonStyle(.plain)
                    }

                    if showsHistory {
                        if payments.history.isEmpty {
                            StudioPaymentHistoryUnavailable(accentColor: accentColor)
                        } else {
                            StudioPaymentHistoryList(groups: payments.history, accentColor: accentColor)
                        }
                    }
                }
            }
        }
    }

    private var historyButtonTitle: String {
        if historyOrderCount > payments.rows.count {
            return "VIEW ALL \(historyOrderCount) PAYMENTS"
        }

        return "VIEW ALL PAYMENTS"
    }
}

private struct StudioTrendsPanel: View {
    let trends: StudioTrends
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StudioPanel(title: "Hourly Pattern", kicker: "Peak \(trends.summary.peakHour)") {
                StudioHourBars(hours: trends.hours, accentColor: accentColor)
            }

            StudioPanel(title: "Trend Notes", kicker: "\(trends.summary.totalOrders) orders") {
                VStack(alignment: .leading, spacing: 12) {
                    StudioMetricLine(label: "Revenue", value: money(trends.summary.totalRevenue))
                    StudioMetricLine(label: "Average order", value: money(trends.summary.averageOrderValue))
                    StudioMetricLine(label: "Peak orders", value: "\(trends.summary.peakOrders)")

                    ForEach(trends.insights) { insight in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(insight.title)
                                .font(GlacialFont.subheadline(.semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text(insight.body)
                                .font(GlacialFont.caption())
                                .foregroundStyle(AppPalette.muted)
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }
}

private struct StudioComparePanel: View {
    let compare: StudioCompare
    let selectedProductA: String
    let selectedProductB: String
    let selectedMetric: String
    let accentColor: Color
    let onChange: (String, String, String) -> Void

    private var productA: String {
        selectedProductA.isEmpty ? compare.productA : selectedProductA
    }

    private var productB: String {
        selectedProductB.isEmpty ? compare.productB : selectedProductB
    }

    private var metric: String {
        selectedMetric.isEmpty ? compare.metric : selectedMetric
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StudioPanel(title: "Compare", kicker: metric.capitalized) {
                VStack(alignment: .leading, spacing: 13) {
                    StudioCompareControls(
                        products: compare.products,
                        productA: productA,
                        productB: productB,
                        metric: metric,
                        accentColor: accentColor,
                        onChange: onChange
                    )

                    HStack(spacing: 12) {
                        StudioCompareTotal(title: compare.productA, value: moneyOrQuantity(compare.totalA, metric: compare.metric), accentColor: accentColor)
                        StudioCompareTotal(title: compare.productB, value: moneyOrQuantity(compare.totalB, metric: compare.metric), accentColor: AppPalette.ink)
                    }

                    StudioCompareLines(points: compare.series, productA: compare.productA, productB: compare.productB, metric: compare.metric, accentColor: accentColor)
                }
            }

            StudioPanel(title: "Difference", kicker: "Selected products") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(compare.differencePercent, specifier: "%.1f")%")
                        .font(GlacialFont.largeTitle(.regular))
                        .foregroundStyle(compare.differencePercent >= 0 ? accentColor : AppPalette.red)
                    Text("\(compare.productA) vs \(compare.productB)")
                        .font(GlacialFont.subheadline())
                        .foregroundStyle(AppPalette.muted)
                    StudioCompareLegend(productA: compare.productA, productB: compare.productB, accentColor: accentColor)
                }
            }
        }
    }
}

private struct StudioPanel<Content: View>: View {
    let title: String
    let kicker: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(kicker.uppercased())
                    .font(GlacialFont.caption2())
                    .tracking(2.7)
                    .foregroundStyle(AppPalette.orange.opacity(0.82))
                Text(title.uppercased())
                    .font(GlacialFont.custom(10.5))
                    .tracking(2.8)
                    .foregroundStyle(AppPalette.ink.opacity(0.76))
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioCompareControls: View {
    let products: [String]
    let productA: String
    let productB: String
    let metric: String
    let accentColor: Color
    let onChange: (String, String, String) -> Void

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                StudioCompareProductMenu(label: "A", value: productA, products: products, accentColor: accentColor) { newValue in
                    onChange(newValue, productB, metric)
                }

                StudioCompareProductMenu(label: "B", value: productB, products: products, accentColor: AppPalette.ink) { newValue in
                    onChange(productA, newValue, metric)
                }
            }

            HStack(spacing: 0) {
                StudioCompareMetricButton(title: "REVENUE", value: "revenue", selectedMetric: metric, accentColor: accentColor) {
                    onChange(productA, productB, "revenue")
                }
                StudioCompareMetricButton(title: "QUANTITY", value: "quantity", selectedMetric: metric, accentColor: accentColor) {
                    onChange(productA, productB, "quantity")
                }
            }
            .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppPalette.line, lineWidth: 1))
        }
    }
}

private struct StudioCompareProductMenu: View {
    let label: String
    let value: String
    let products: [String]
    let accentColor: Color
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            if products.isEmpty {
                Text("No products synced")
            } else {
                ForEach(products, id: \.self) { product in
                    Button {
                        onSelect(product)
                    } label: {
                        Label(product, systemImage: product == value ? "checkmark" : "circle")
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(GlacialFont.caption2(.medium))
                    .tracking(1.8)
                    .foregroundStyle(accentColor)
                    .frame(width: 18, height: 18)
                    .background(accentColor.opacity(0.10), in: Circle())

                Text(value.isEmpty ? "Select product" : value)
                    .font(GlacialFont.custom(11.5, .medium))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppPalette.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppPalette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(products.isEmpty)
    }
}

private struct StudioCompareMetricButton: View {
    let title: String
    let value: String
    let selectedMetric: String
    let accentColor: Color
    let action: () -> Void

    private var isSelected: Bool {
        selectedMetric == value
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(GlacialFont.caption2(.medium))
                .tracking(2.0)
                .foregroundStyle(isSelected ? accentColor : AppPalette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? accentColor.opacity(0.09) : .clear)
        }
        .buttonStyle(.plain)
    }
}

private struct StudioRevenueChartPoint: Identifiable {
    let id: String
    let label: String
    let revenue: Double
}

private struct StudioBarChart: View {
    let rows: [StudioRevenueChartPoint]
    let accentColor: Color

    private var maxValue: Double {
        max(rows.map(\.revenue).max() ?? 0, 1)
    }

    private var labelStride: Int {
        rows.count > 16 ? 5 : (rows.count > 10 ? 2 : 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: rows.count > 20 ? 4 : 8) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accentColor)
                        .frame(height: CGFloat(max(8, 116 * row.revenue / maxValue)))
                    Text(index % labelStride == 0 ? row.label.prefix(2).uppercased() : "")
                        .font(GlacialFont.caption2())
                        .tracking(0.8)
                        .foregroundStyle(AppPalette.muted.opacity(0.9))
                        .frame(height: 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 154)
    }
}

private struct StudioHourBars: View {
    let hours: [StudioHourMetric]
    let accentColor: Color

    private var maxOrders: Int {
        max(hours.map(\.orders).max() ?? 0, 1)
    }

    var body: some View {
        VStack(spacing: 9) {
            ForEach(hours) { hour in
                HStack(spacing: 10) {
                    Text(hour.hour)
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(AppPalette.muted)
                        .frame(width: 48, alignment: .leading)

                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accentColor.opacity(hour.orders > 0 ? 0.84 : 0.12))
                            .frame(width: max(6, proxy.size.width * CGFloat(hour.orders) / CGFloat(maxOrders)))
                    }
                    .frame(height: 10)

                    Text("\(hour.orders)")
                        .font(GlacialFont.caption(.bold))
                        .foregroundStyle(AppPalette.ink)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
    }
}

private struct StudioCompareLines: View {
    let points: [StudioComparePoint]
    let productA: String
    let productB: String
    let metric: String
    let accentColor: Color

    private var visiblePoints: [StudioComparePoint] {
        Array(points.prefix(30))
    }

    private var maxValue: Double {
        max(visiblePoints.flatMap { [$0.a, $0.b] }.max() ?? 0, 1)
    }

    private var labelStride: Int {
        visiblePoints.count > 20 ? 6 : (visiblePoints.count > 10 ? 3 : 2)
    }

    private var productBColor: Color {
        Color(red: 0.102, green: 0.220, blue: 0.431)
    }

    private var productAColor: Color {
        AppPalette.orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioCompareLegend(productA: productA, productB: productB, accentColor: productAColor, productBColor: productBColor)

            if visiblePoints.isEmpty || visiblePoints.allSatisfy({ $0.a == 0 && $0.b == 0 }) {
                StudioMiniEmpty(message: "No \(metric) data for this comparison.")
                    .frame(height: 118)
            } else {
                VStack(spacing: 8) {
                    GeometryReader { proxy in
                        ZStack {
                            VStack(spacing: 0) {
                                ForEach(0..<4, id: \.self) { _ in
                                    Rectangle()
                                        .fill(AppPalette.line.opacity(0.72))
                                        .frame(height: 1)
                                    Spacer()
                                }
                            }

                            comparePath(for: \.a, in: proxy.size)
                                .stroke(productAColor, style: StrokeStyle(lineWidth: 2.9, lineCap: .round, lineJoin: .round))
                                .shadow(color: productAColor.opacity(0.16), radius: 5, x: 0, y: 2)

                            comparePath(for: \.b, in: proxy.size)
                                .stroke(productBColor, style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round))
                                .shadow(color: productBColor.opacity(0.14), radius: 5, x: 0, y: 2)

                            ForEach(Array(visiblePoints.enumerated()), id: \.element.id) { index, point in
                                Circle()
                                    .fill(productAColor)
                                    .frame(width: 5.5, height: 5.5)
                                    .position(position(index: index, value: point.a, in: proxy.size))

                                Circle()
                                    .fill(productBColor)
                                    .frame(width: 5.5, height: 5.5)
                                    .position(position(index: index, value: point.b, in: proxy.size))
                            }
                        }
                    }
                    .frame(height: 110)

                    HStack(spacing: 0) {
                        ForEach(Array(visiblePoints.enumerated()), id: \.element.id) { index, point in
                            Text(index % labelStride == 0 || index == visiblePoints.count - 1 ? point.label.prefix(2).uppercased() : "")
                                .font(GlacialFont.caption2())
                                .tracking(0.7)
                                .foregroundStyle(AppPalette.muted)
                                .frame(height: 12)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func comparePath(for keyPath: KeyPath<StudioComparePoint, Double>, in size: CGSize) -> Path {
        var path = Path()
        let coordinates = visiblePoints.enumerated().map { index, point in
            position(index: index, value: point[keyPath: keyPath], in: size)
        }

        for (index, coordinate) in coordinates.enumerated() {
            if index == 0 {
                path.move(to: coordinate)
            } else {
                let previous = coordinates[index - 1]
                let midpoint = CGPoint(
                    x: (previous.x + coordinate.x) / 2,
                    y: (previous.y + coordinate.y) / 2
                )
                path.addQuadCurve(to: midpoint, control: previous)

                if index == coordinates.count - 1 {
                    path.addQuadCurve(to: coordinate, control: coordinate)
                }
            }
        }

        return path
    }

    private func position(index: Int, value: Double, in size: CGSize) -> CGPoint {
        let count = max(visiblePoints.count - 1, 1)
        let x = CGFloat(index) / CGFloat(count) * size.width
        let topPadding: CGFloat = 6
        let bottomPadding: CGFloat = 8
        let availableHeight = max(1, size.height - topPadding - bottomPadding)
        let normalized = CGFloat(value / maxValue)
        let y = topPadding + availableHeight * (1 - normalized)

        return CGPoint(x: x, y: y)
    }
}

private struct StudioCompareLegend: View {
    let productA: String
    let productB: String
    let accentColor: Color
    var productBColor = Color(red: 0.102, green: 0.220, blue: 0.431)

    var body: some View {
        HStack(spacing: 12) {
            StudioLegendItem(color: accentColor, text: productA)
            StudioLegendItem(color: productBColor, text: productB)
        }
    }
}

private struct StudioLegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 6)
            Text(text.isEmpty ? "SELECT PRODUCT" : text.uppercased())
                .font(GlacialFont.custom(9, .medium))
                .tracking(1.4)
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
        }
    }
}

private struct StudioMiniEmpty: View {
    let message: String

    var body: some View {
        Text(message)
            .font(GlacialFont.caption())
            .foregroundStyle(AppPalette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioPaymentPie: View {
    let metrics: [StudioPaymentMetric]
    let accentColor: Color

    private var total: Double {
        max(metrics.reduce(0) { $0 + $1.revenue }, 0)
    }

    private var segments: [StudioPaymentPieSegment] {
        guard total > 0 else { return [] }

        var cursor = 0.0

        return metrics.enumerated().map { index, metric in
            let share = metric.revenue / total
            let segment = StudioPaymentPieSegment(
                id: metric.id,
                start: cursor,
                end: cursor + share,
                color: paymentColor(for: metric.method, index: index, accentColor: accentColor)
            )
            cursor += share
            return segment
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Ellipse()
                    .fill(AppPalette.ink.opacity(0.08))
                    .frame(width: 106, height: 20)
                    .blur(radius: 5)
                    .offset(y: 43)

                ZStack {
                    ForEach(segments) { segment in
                        StudioPaymentPieSlice(start: segment.start, end: segment.end, inset: 0.018)
                            .fill(paymentDepthColor(segment.color))
                            .offset(x: segment.offset.width * 0.72, y: segment.offset.height + 9)
                    }

                    ForEach(segments) { segment in
                        StudioPaymentPieSlice(start: segment.start, end: segment.end, inset: 0.018)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        segment.color.opacity(0.98),
                                        segment.color.opacity(0.72)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                StudioPaymentPieSlice(start: segment.start, end: segment.end, inset: 0.018)
                                    .stroke(Color.white.opacity(0.70), lineWidth: 1)
                            }
                            .offset(segment.offset)
                            .shadow(color: segment.color.opacity(0.18), radius: 7, x: 0, y: 4)
                    }

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.36),
                                    Color.white.opacity(0.02)
                                ],
                                center: .topLeading,
                                startRadius: 4,
                                endRadius: 68
                            )
                        )
                        .scaleEffect(x: 1, y: 0.58)
                        .offset(y: -7)
                        .allowsHitTesting(false)
                }
                .frame(width: 108, height: 108)
                .scaleEffect(x: 1.05, y: 0.72)
                .rotationEffect(.degrees(-8))
                .offset(y: 2)
            }
            .frame(height: 88)

            VStack(spacing: 1) {
                Text(compactMoney(total))
                    .font(GlacialFont.custom(17, .regular))
                    .monospacedDigit()
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("VND")
                    .font(GlacialFont.custom(8, .medium))
                    .tracking(1.7)
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .accessibilityLabel("Payment mix")
    }
}

private struct StudioPaymentPieSegment: Identifiable {
    let id: String
    let start: Double
    let end: Double
    let color: Color

    var mid: Double {
        (start + end) / 2
    }

    var offset: CGSize {
        let angle = ((mid * 360) - 90) * .pi / 180
        return CGSize(width: cos(angle) * 1.8, height: sin(angle) * 1.8)
    }
}

private struct StudioPaymentPieSlice: Shape {
    let start: Double
    let end: Double
    let inset: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let sweep = max(0, (end - start) * 360)
        let gap = min(inset * 180, sweep * 0.22)
        let startAngle = Angle(degrees: start * 360 - 90 + gap)
        let endAngle = Angle(degrees: end * 360 - 90 - gap)

        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct StudioPaymentMixRow: View {
    let metric: StudioPaymentMetric
    let index: Int
    let accentColor: Color

    private var color: Color {
        paymentColor(for: metric.method, index: index, accentColor: accentColor)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            StudioFlatRow(
                title: paymentDisplayLabel(metric),
                meta: "\(metric.orders) orders",
                value: money(metric.revenue),
                titleStyle: .paymentMix
            )
        }
    }
}

private struct StudioPaymentHistoryList: View {
    let groups: [StudioPaymentHistoryGroup]
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                StudioDisclosureRow(title: group.label, meta: "\(group.orders) orders", value: money(group.revenue), rowStyle: .reportWeek) {
                    ForEach(group.days) { day in
                        StudioDisclosureRow(title: day.label, meta: "\(day.orders) orders", value: money(day.revenue), rowStyle: .reportDay) {
                            ForEach(day.rows) { row in
                                StudioFlatRow(
                                    title: row.orderNumber,
                                    meta: "\(row.methodLabel) · \(row.sourceLabel)",
                                    value: money(row.total),
                                    titleStyle: .paymentOrder
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppPalette.line)
                .frame(height: 1)
        }
    }
}

private struct StudioPaymentHistoryUnavailable: View {
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accentColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("HISTORY NOT SYNCED")
                    .font(GlacialFont.caption2(.medium))
                    .tracking(2.0)
                    .foregroundStyle(AppPalette.ink)
                Text("Deploy the Studio API update to load all payments by week and day.")
                    .font(GlacialFont.caption())
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppPalette.line)
                .frame(height: 1)
        }
    }
}

private struct StudioRankedRow: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let note: String
}

private struct StudioRankedRows: View {
    let rows: [StudioRankedRow]
    var titleStyle: StudioFlatRowTitleStyle = .standard

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                StudioFlatRow(title: row.title, meta: row.note, value: row.value, titleStyle: titleStyle)
            }
        }
    }
}

private enum StudioFlatRowTitleStyle {
    case standard
    case trackedProduct
    case reportWeek
    case reportDay
    case paymentMix
    case paymentOrder

    var titleFont: Font {
        switch self {
        case .trackedProduct:
            return GlacialFont.custom(13.5, .regular)
        case .reportWeek:
            return GlacialFont.custom(10, .semibold)
        case .reportDay:
            return GlacialFont.custom(10, .medium)
        case .paymentMix:
            return GlacialFont.custom(11, .medium)
        case .paymentOrder:
            return GlacialFont.subheadline(.semibold)
        case .standard:
            return GlacialFont.subheadline(.semibold)
        }
    }

    var titleTracking: CGFloat {
        switch self {
        case .trackedProduct:
            return 1.2
        case .reportWeek:
            return 1.6
        case .reportDay:
            return 1.2
        case .paymentMix:
            return 1.8
        case .paymentOrder:
            return 0
        case .standard:
            return 0
        }
    }

    var titleColor: Color {
        switch self {
        case .reportWeek:
            return AppPalette.orange
        case .reportDay:
            return Color(red: 0.337, green: 0.314, blue: 0.290)
        case .standard, .trackedProduct, .paymentMix, .paymentOrder:
            return AppPalette.ink
        }
    }

    var metaTracking: CGFloat {
        switch self {
        case .reportWeek:
            return 0.8
        case .reportDay:
            return 0.6
        case .paymentMix:
            return 0.8
        case .paymentOrder:
            return 1.1
        case .standard, .trackedProduct:
            return 0
        }
    }

    var valueFont: Font {
        switch self {
        case .reportWeek:
            return GlacialFont.custom(11, .medium)
        case .reportDay:
            return GlacialFont.custom(10, .medium)
        case .paymentMix:
            return GlacialFont.custom(11, .medium)
        case .standard, .trackedProduct, .paymentOrder:
            return GlacialFont.caption(.bold)
        }
    }

    var valueTracking: CGFloat {
        switch self {
        case .reportWeek:
            return 0.2
        case .reportDay:
            return 0
        case .paymentMix:
            return 0.2
        case .standard, .trackedProduct, .paymentOrder:
            return 1.1
        }
    }

    var uppercasesMeta: Bool {
        self == .paymentOrder
    }
}

private struct StudioFlatRow: View {
    let title: String
    let meta: String
    let value: String
    var titleStyle: StudioFlatRowTitleStyle = .standard

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(titleStyle.titleFont)
                    .tracking(titleStyle.titleTracking)
                    .foregroundStyle(titleStyle.titleColor)
                    .textCase(titleStyle == .reportWeek || titleStyle == .reportDay || titleStyle == .paymentMix ? .uppercase : nil)
                    .lineLimit(1)
                Text(meta)
                    .font(GlacialFont.caption())
                    .tracking(titleStyle.metaTracking)
                    .foregroundStyle(AppPalette.muted)
                    .textCase(titleStyle.uppercasesMeta ? .uppercase : nil)
                    .lineLimit(1)
            }

            Spacer()

            Text(value)
                .font(titleStyle.valueFont)
                .tracking(titleStyle.valueTracking)
                .monospacedDigit()
                .foregroundStyle(titleStyle == .reportDay ? Color(red: 0.337, green: 0.314, blue: 0.290) : AppPalette.ink)
                .lineLimit(1)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppPalette.line)
                .frame(height: 1)
        }
    }
}

private struct StudioDisclosureRow<Content: View>: View {
    let title: String
    let meta: String
    let value: String
    var rowStyle: StudioFlatRowTitleStyle = .standard
    @ViewBuilder let content: () -> Content
    @State private var isOpen = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isOpen.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(AppPalette.muted)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    StudioFlatRow(title: title, meta: meta, value: value, titleStyle: rowStyle)
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 0) {
                    content()
                }
                .padding(.leading, 28)
            }
        }
    }
}

private struct StudioMetricLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label.uppercased())
                .font(GlacialFont.caption2())
                .tracking(2.4)
                .foregroundStyle(AppPalette.muted)
            Spacer()
            Text(value)
                .font(GlacialFont.subheadline(.semibold))
                .foregroundStyle(AppPalette.ink)
        }
    }
}

private struct StudioCompareTotal: View {
    let title: String
    let value: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(GlacialFont.caption(.bold))
                .tracking(1.4)
                .foregroundStyle(AppPalette.muted)
                .lineLimit(1)
            Text(value)
                .font(GlacialFont.title3(.regular))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppPalette.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StudioNotice: View {
    let message: String
    let accentColor: Color
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(accentColor)
            Text(message)
                .font(GlacialFont.subheadline())
                .foregroundStyle(AppPalette.ink)
            Spacer()
            Button("Retry", action: retry)
                .font(GlacialFont.caption(.bold))
                .foregroundStyle(accentColor)
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private struct StudioEmptyState: View {
    let isLoading: Bool
    let accentColor: Color

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .tint(accentColor)
            }
            Text(isLoading ? "Loading Studio" : "Studio is waiting for data")
                .font(GlacialFont.title3(.regular))
                .foregroundStyle(AppPalette.ink)
            Text("Add the Studio token in Settings, then open Studio from the hidden admin menu.")
                .font(GlacialFont.subheadline())
                .foregroundStyle(AppPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppPalette.line, lineWidth: 1))
    }
}

private func money(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return (formatter.string(from: NSNumber(value: value)) ?? "0") + " VND"
}

private func moneyOrQuantity(_ value: Double, metric: String) -> String {
    if metric == "quantity" {
        return "\(Int(value))"
    }

    return money(value)
}

private func formatQuantity(_ value: Double, unit: String) -> String {
    let cleanValue = value.rounded() == value
        ? String(format: "%.0f", value)
        : String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    let cleanUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)

    return cleanUnit.isEmpty ? cleanValue : "\(cleanValue) \(cleanUnit)"
}

private func cleanNumber(_ value: Double) -> String {
    value.rounded() == value
        ? String(format: "%.0f", value)
        : String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
}

private func parseDouble(_ value: String) -> Double {
    Double(value.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

private func compactMoney(_ value: Double) -> String {
    if value >= 1_000_000 {
        let millions = value / 1_000_000
        return String(format: millions >= 10 ? "%.0fM" : "%.1fM", millions)
            .replacingOccurrences(of: ".0M", with: "M")
    }

    if value >= 1_000 {
        return "\(Int(value / 1_000))K"
    }

    return "\(Int(value))"
}

private func paymentDisplayLabel(_ payment: StudioPaymentMetric) -> String {
    let method = payment.method.lowercased()

    if method.contains("qr") {
        return "QR"
    }

    if method.contains("bank") {
        return "BANK"
    }

    if method.contains("cash") {
        return "CASH"
    }

    return payment.label.uppercased()
}

private func paymentColor(for method: String, index: Int, accentColor: Color) -> Color {
    let value = method.lowercased()

    if value.contains("cash") {
        return accentColor
    }

    if value.contains("qr") {
        return AppPalette.green
    }

    if value.contains("bank") {
        return Color(red: 0.337, green: 0.314, blue: 0.290)
    }

    let fallbacks = [
        Color(red: 0.694, green: 0.443, blue: 0.275),
        Color(red: 0.463, green: 0.427, blue: 0.365),
        AppPalette.muted
    ]

    return fallbacks[index % fallbacks.count]
}

private func paymentDepthColor(_ color: Color) -> Color {
    color.opacity(0.58)
}

private struct StudioAPIErrorResponse: Decodable {
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
