import Foundation
import UserNotifications

public protocol UserNotificationCenterProtocol: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    @MainActor func removePendingNotificationRequests(withIdentifiers ids: [String])
    func pendingNotificationRequests() async -> [UNNotificationRequest]
}

public final class SystemUserNotificationCenter: UserNotificationCenterProtocol {
    private let center: UNUserNotificationCenter
    public init(center: UNUserNotificationCenter = .current()) { self.center = center }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
    public func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
    @MainActor public func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    public func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }
}
