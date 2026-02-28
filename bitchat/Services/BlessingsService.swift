
//
// BlessingsService.swift
// bitchat
//
// Manages the Blessings Q&A feature.
// One user asks a question; up to 30 peers vote Yes, No, or Wait.
// All communication uses the bitchat mesh transport (BLE broadcast messages).
//

import Foundation
import Combine

// MARK: - Message Protocol Constants

/// Blessing message protocol uses a structured text prefix in regular broadcast messages.
/// Format for questions:  "BLESSING_Q|{id}|{questionText}"
/// Format for responses:  "BLESSING_R|{questionId}|{responseType}|{responderNickname}"
/// responseType is one of: yes | no | wait
struct BlessingMessageProtocol {
    static let questionPrefix = "BLESSING_Q|"
    static let responsePrefix = "BLESSING_R|"
    static let maxResponders = 30

    static func encodeQuestion(id: String, question: String) -> String {
        return "\(questionPrefix)\(id)|\(question)"
    }

    static func encodeResponse(questionId: String, response: BlessingResponse, responderNickname: String) -> String {
        return "\(responsePrefix)\(questionId)|\(response.rawValue)|\(responderNickname)"
    }

    /// Returns (id, question) if the message is a blessing question.
    static func decodeQuestion(from content: String) -> (id: String, question: String)? {
        guard content.hasPrefix(questionPrefix) else { return nil }
        let body = String(content.dropFirst(questionPrefix.count))
        let parts = body.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (id: parts[0], question: parts[1])
    }

    /// Returns (questionId, response, nickame) if the message is a blessing response.
    static func decodeResponse(from content: String) -> (questionId: String, response: BlessingResponse, nickname: String)? {
        guard content.hasPrefix(responsePrefix) else { return nil }
        let body = String(content.dropFirst(responsePrefix.count))
        let parts = body.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              let response = BlessingResponse(rawValue: parts[1]) else { return nil }
        return (questionId: parts[0], response: response, nickname: parts[2])
    }
}

// MARK: - Data Models

enum BlessingResponse: String, Codable {
    case yes = "yes"
    case no = "no"
    case wait = "wait"

    var emoji: String {
        switch self {
        case .yes: return "🌿"
        case .no: return "🌼"
        case .wait: return "🌸"
        }
    }

    var label: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .wait: return "Wait"
        }
    }
}

struct BlessingVote: Identifiable {
    let id: String
    let voterNickname: String
    let response: BlessingResponse
    let timestamp: Date
}

// Represents an active blessing question that has been broadcast
class BlessingQuestion: ObservableObject, Identifiable {
    let id: String
    let question: String
    let askerNickname: String
    let isOwnQuestion: Bool
    let timestamp: Date

    @Published var votes: [BlessingVote] = []
    @Published var hasResponded: Bool = false

    var yesCount: Int { votes.filter { $0.response == .yes }.count }
    var noCount: Int { votes.filter { $0.response == .no }.count }
    var waitCount: Int { votes.filter { $0.response == .wait }.count }
    var totalCount: Int { votes.count }
    var isFull: Bool { votes.count >= BlessingMessageProtocol.maxResponders }

    // Unique voters set (prevent duplicate votes per person)
    private var voterNames = Set<String>()

    init(id: String, question: String, askerNickname: String, isOwnQuestion: Bool, timestamp: Date) {
        self.id = id
        self.question = question
        self.askerNickname = askerNickname
        self.isOwnQuestion = isOwnQuestion
        self.timestamp = timestamp
    }

    /// Returns true if the vote was accepted, false if the voter already voted or the poll is full.
    @discardableResult
    func addVote(from nickname: String, response: BlessingResponse) -> Bool {
        guard !isFull, !voterNames.contains(nickname.lowercased()) else { return false }
        let vote = BlessingVote(id: UUID().uuidString, voterNickname: nickname, response: response, timestamp: Date())
        votes.append(vote)
        voterNames.insert(nickname.lowercased())
        return true
    }

    /// Serialise to a JS-compatible dictionary
    var jsPayload: [String: Any] {
        return [
            "id": id,
            "question": question,
            "askerNickname": askerNickname,
            "isOwnQuestion": isOwnQuestion,
            "timestamp": timestamp.timeIntervalSince1970 * 1000,
            "yesCount": yesCount,
            "noCount": noCount,
            "waitCount": waitCount,
            "totalCount": totalCount,
            "isFull": isFull,
            "hasResponded": hasResponded,
            "votes": votes.map { [
                "voterNickname": $0.voterNickname,
                "response": $0.response.rawValue,
                "emoji": $0.response.emoji
            ]}
        ]
    }
}

// MARK: - BlessingsService

/// Manages the lifecycle of blessing Q&A sessions.
/// Receives broadcast messages and parses BLESSING_ protocol messages.
/// Notifies observers via Combine publishers.
final class BlessingsService: ObservableObject {

    static let shared = BlessingsService()

    @Published var activeQuestions: [BlessingQuestion] = []  // most recent first
    @Published var newQuestionReceived: BlessingQuestion?    // triggers UI notification

    /// Called by BlessingsView to forward incoming messages for parsing
    var onJSEvent: ((String) -> Void)?   // closure to evaluate JS in the WebView

    private var myNickname: String = "anon"
    private let maxActiveQuestions = 10

    private init() {}

    func configure(nickname: String) {
        self.myNickname = nickname
    }

    // MARK: - Outbound

    /// Broadcast a new blessing question via bitchat transport.
    /// Returns the new BlessingQuestion so the caller can track it.
    @discardableResult
    func broadcastQuestion(_ text: String, transport: Transport) -> BlessingQuestion {
        let id = generateID()
        let question = BlessingQuestion(
            id: id,
            question: text,
            askerNickname: myNickname,
            isOwnQuestion: true,
            timestamp: Date()
        )
        addQuestion(question)
        let encoded = BlessingMessageProtocol.encodeQuestion(id: id, question: text)
        transport.sendMessage(encoded, mentions: [])
        return question
    }

    /// Broadcast a blessing response (yes/no/wait) via bitchat transport.
    func broadcastResponse(questionId: String, response: BlessingResponse, transport: Transport) {
        guard let question = findQuestion(id: questionId) else { return }
        guard !question.isFull, !question.hasResponded else { return }
        question.hasResponded = true

        // Apply to local model immediately for instant feedback
        question.addVote(from: myNickname, response: response)

        let encoded = BlessingMessageProtocol.encodeResponse(questionId: questionId, response: response, responderNickname: myNickname)
        transport.sendMessage(encoded, mentions: [])
        notifyJS(question: question)
    }

    // MARK: - Inbound

    /// Call this for every public bitchat message received.
    func handleIncomingMessage(from sender: String, content: String) {
        if let decoded = BlessingMessageProtocol.decodeQuestion(from: content) {
            // Ignore questions from ourselves (we already added them locally)
            guard sender.lowercased() != myNickname.lowercased() else { return }
            let question = BlessingQuestion(
                id: decoded.id,
                question: decoded.question,
                askerNickname: sender,
                isOwnQuestion: false,
                timestamp: Date()
            )
            addQuestion(question)
            DispatchQueue.main.async { [weak self] in
                self?.newQuestionReceived = question
            }
            notifyJS(question: question)
        } else if let decoded = BlessingMessageProtocol.decodeResponse(from: content) {
            guard let question = findQuestion(id: decoded.questionId) else { return }
            let accepted = question.addVote(from: decoded.nickname, response: decoded.response)
            if accepted {
                notifyJS(question: question)
            }
        }
    }

    // MARK: - Private helpers

    private func addQuestion(_ question: BlessingQuestion) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Avoid duplicates
            if self.activeQuestions.contains(where: { $0.id == question.id }) { return }
            self.activeQuestions.insert(question, at: 0)
            // Trim to max
            if self.activeQuestions.count > self.maxActiveQuestions {
                self.activeQuestions = Array(self.activeQuestions.prefix(self.maxActiveQuestions))
            }
        }
    }

    private func findQuestion(id: String) -> BlessingQuestion? {
        return activeQuestions.first { $0.id == id }
    }

    private func generateID() -> String {
        return String(UUID().uuidString.prefix(8).lowercased())
    }

    /// Serialize the question state to JSON and call the JS bridge
    private func notifyJS(question: BlessingQuestion) {
        guard let jsCallback = onJSEvent else { return }
        DispatchQueue.main.async {
            guard let data = try? JSONSerialization.data(withJSONObject: question.jsPayload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.onBlessingUpdate && window.onBlessingUpdate(\(json));"
            jsCallback(js)
        }
    }

    /// Push all active questions to JS (called after WebView finishes loading)
    func syncAllQuestionsToJS() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for question in self.activeQuestions {
                self.notifyJS(question: question)
            }
        }
    }
}
