import Foundation
import SwiftData

@Model
public final class ChatMessage {
    @Attribute(.unique) public var id: UUID = UUID()
    public var roleRaw: String = ChatRole.user.rawValue
    public var text: String = ""
    public var toolCallsJSON: String?
    public var toolResultsJSON: String?
    public var conversationId: UUID = UUID()
    public var createdAt: Date = Date()

    public var role: ChatRole {
        get { ChatRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        conversationId: UUID
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.conversationId = conversationId
    }
}
