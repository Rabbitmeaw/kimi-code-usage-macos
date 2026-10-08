import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published var corner: AttachmentCorner = .bottomRight
    @Published var snapshot: QuotaSnapshot?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var targetStatus: String?
    @Published var layoutNotice: String?
    @Published var bandSettings: QuotaBandSettings = .defaults
}
