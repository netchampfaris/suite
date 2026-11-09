import Foundation

/// Any JSON value, kept as the server sent it so it can be sent back unchanged.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        // Numbers first, so a `1` never comes back as `true`.
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    /// Reads JSON text, such as the parameters mediasoup hands back.
    init(text: String) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Reads what `JSONSerialization` or socket.io produced.
    init(foundation object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The value as JSON text, the form mediasoup takes its parameters in.
    var text: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// The value as Foundation objects, the form socket.io sends.
    var foundation: Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) ?? NSNull()
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
