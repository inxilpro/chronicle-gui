import AppKit
import ChronicleKit
import UserNotifications

/// Posts decision and coalesced-message notifications and routes their
/// actions back through the model, exactly like the in-app buttons.
@MainActor
final class NotificationController: NSObject {
    static let decisionCategory = "CHRONICLE_DECISION"
    static let approveAction = "CHRONICLE_APPROVE"
    static let rejectAction = "CHRONICLE_REJECT"
    static let coalescedIdentifier = "chronicle-new-messages"

    weak var model: AppModel?

    private var authorized = false
    private var seenMessageIDs: Set<String> = []
    private var coalescedCount = 0

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(
            identifier: Self.approveAction, title: "Approve", options: [])
        let reject = UNNotificationAction(
            identifier: Self.rejectAction, title: "Reject", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: Self.decisionCategory, actions: [approve, reject],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor [weak self] in
                self?.authorized = granted
            }
        }
    }

    /// Requested at first session start, never at launch.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, _ in
            Task { @MainActor [weak self] in
                self?.authorized = granted
            }
        }
    }

    func process(snapshot: AppSnapshot, baseline: Bool) {
        let unread = snapshot.messages.filter { $0.kind != .ack && !$0.read }
        defer {
            for message in snapshot.messages where message.kind != .ack {
                seenMessageIDs.insert(message.id)
            }
        }
        if baseline {
            // The launch backlog renders in the feed; only messages that
            // arrive while the app is running notify.
            return
        }
        clearReadDecisions(snapshot: snapshot)
        if unread.filter({ $0.kind == .message }).isEmpty {
            clearCoalesced()
        }
        guard authorized else { return }
        let defaults = UserDefaults.standard
        let fresh = unread.filter { !seenMessageIDs.contains($0.id) }
        if defaults.bool(forKey: SettingsKey.notifyDecisions) {
            for decision in fresh
            where decision.kind == .decision && decision.decisionStatus == .unreviewed {
                postDecision(decision, sessionId: snapshot.sessionId)
            }
        }
        let freshMessages = fresh.filter { $0.kind == .message }
        if !freshMessages.isEmpty, defaults.bool(forKey: SettingsKey.notifyMessages) {
            coalescedCount += freshMessages.count
            postCoalesced(latest: freshMessages.last, sessionId: snapshot.sessionId)
        }
    }

    private func postDecision(_ message: ChatMessage, sessionId: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Decision requested"
        content.body = message.text
        content.categoryIdentifier = Self.decisionCategory
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId ?? "",
            "messageId": message.id,
        ]
        let request = UNNotificationRequest(
            identifier: "chronicle-decision-\(message.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func postCoalesced(latest: ChatMessage?, sessionId: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Chronicle"
        content.body = FeedFormat.coalescedMessageBody(coalescedCount)
        content.userInfo = [
            "sessionId": sessionId ?? "",
            "messageId": latest?.id ?? "",
        ]
        let request = UNNotificationRequest(
            identifier: Self.coalescedIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clearCoalesced() {
        guard coalescedCount > 0 else { return }
        coalescedCount = 0
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.coalescedIdentifier])
    }

    func removeDelivered(decisionId: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["chronicle-decision-\(decisionId)"])
    }

    private func clearReadDecisions(snapshot: AppSnapshot) {
        let settled = snapshot.messages
            .filter { $0.kind == .decision && ($0.read || $0.decisionStatus != .unreviewed) }
            .map { "chronicle-decision-\($0.id)" }
        if !settled.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: settled)
        }
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The feed itself shows new activity while the app is frontmost.
        await MainActor.run { NSApplication.shared.isActive ? [] : [.banner, .sound] }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String
        let messageId = userInfo["messageId"] as? String
        let action = response.actionIdentifier
        await MainActor.run { [weak self] in
            guard let model = self?.model else { return }
            switch action {
            case Self.approveAction:
                if let messageId, let sessionId, !sessionId.isEmpty {
                    model.review(sessionId: sessionId, decisionId: messageId, as: .approved)
                }
            case Self.rejectAction:
                if let messageId, let sessionId, !sessionId.isEmpty {
                    model.review(sessionId: sessionId, decisionId: messageId, as: .rejected)
                }
            default:
                NSApplication.shared.activate()
                model.openMainWindow?()
                if let messageId, !messageId.isEmpty {
                    model.feedScrollTarget = messageId
                }
            }
        }
    }
}
