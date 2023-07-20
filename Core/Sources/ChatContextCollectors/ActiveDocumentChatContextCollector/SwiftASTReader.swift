import ASTParser
import Foundation
import SuggestionModel

protocol ASTReader {
    func contextContainingRange(
        _ range: CursorRange,
        code: String,
        codeLines: [String]
    ) -> CodeContext
}

struct CodeContext: CustomStringConvertible {
    enum Scope {
        case top
        case scope(
            type: String,
            identifier: String,
            range: CursorRange
        )
    }

    var scope: Scope
    var extraKnowledge: String = ""

    var description: String {
        switch scope {
        case .top:
            return "\(extraKnowledge)"
        case let .scope(type, identifier, range):
            return """
            Inside \(type) \(identifier), range \(range)
            \(extraKnowledge)
            """
        }
    }
}

struct SwiftASTReader: ASTReader {
    enum ScopeType: String, CaseIterable {
        case protocolDeclaration = "protocol_declaration"
        case classDeclaration = "class_declaration"
        case functionDeclaration = "function_declaration"
        case propertyDeclaration = "property_declaration"
        case computedProperty = "computed_property"
    }
    
    func createExtraKnowledge(_ code: String) -> String {
        var all = [String]()
        if code.contains("macro") {
            all.append("macro: introduced since Swift 5.9")
        }
        return all.joined()
    }

    func contextContainingRange(
        _ range: CursorRange,
        code: String,
        codeLines: [String]
    ) -> CodeContext {
        let parser = ASTParser(language: .swift)
        guard let tree = parser.parse(code) else {
            return .init(scope: .top)
        }

        guard let node = tree.smallestNodeContainingRange(range, filter: { node in
            ScopeType.allCases.map { $0.rawValue }.contains(node.nodeType)
        }) else {
            return .init(scope: .top)
        }

        switch ScopeType(rawValue: node.nodeType ?? "") {
        case .protocolDeclaration:
            // Example:
            // comment [0, 0] - [1, 10]
            // comment [1, 0] - [1, 10]
            // protocol_declaration [2, 0] - [5, 1]
            //   protocol [2, 0] - [2, 8]
            //   type_identifier [2, 9] - [2, 15]
            //   protocol_body [2, 16] - [5, 1]
            //     { [2, 16] - [2, 17]
            //     protocol_property_declaration [3, 4] - [3, 28]
            //       ...
            //     protocol_function_declaration [4, 4] - [4, 16]
            //       ...
            //     } [5, 0] - [5, 1]

            var identifier = "unknown"
            for child in node.children {
                if child.nodeType == "type_identifier" {
                    let range = CursorRange(pointRange: child.pointRange)
                    let (code, _) = EditorInformation.code(in: codeLines, inside: range)
                    identifier = code
                    break
                }
            }
            return .init(scope: .scope(
                type: "protocol",
                identifier: identifier,
                range: .init(pointRange: node.pointRange)
            ))

        case .classDeclaration:
            // class_declaration [9, 0] - [14, 1]
            //   struct [9, 0] - [9, 6]
            //   type_identifier [9, 7] - [9, 10]
            //   : [9, 10] - [9, 11]
            //   inheritance_specifier [9, 12] - [9, 18]
            //     user_type [9, 12] - [9, 18]
            //       type_identifier [9, 12] - [9, 18]
            //   class_body [9, 19] - [14, 1]
            //     { [9, 19] - [9, 20]
            //     property_declaration [10, 4] - [10, 20]
            //       let [10, 4] - [10, 7]
            //       pattern [10, 8] - [10, 12]
            //         simple_identifier [10, 8] - [10, 12]
            //       type_annotation [10, 12] - [10, 20]
            //         : [10, 12] - [10, 13]
            //         user_type [10, 14] - [10, 20]
            //           type_identifier [10, 14] - [10, 20]
            //     function_declaration [11, 4] - [13, 5]
            //       ...
            //     } [14, 0] - [14, 1]
            // can be struct, enum, class, or actor

            var type = "unknown"
            var identifier = "unknown"

            for child in node.children {
                switch child.nodeType {
                case "struct":
                    type = "struct"
                case "class":
                    type = "class"
                case "enum":
                    type = "enum"
                case "actor":
                    type = "actor"
                case "type_identifier":
                    let range = CursorRange(pointRange: child.pointRange)
                    let (code, _) = EditorInformation.code(in: codeLines, inside: range)
                    identifier = code
                default: continue
                }
            }

            return .init(scope: .scope(
                type: type,
                identifier: identifier,
                range: .init(pointRange: node.pointRange)
            ))

        case .functionDeclaration:
            return .init(scope: .top)
        case .propertyDeclaration:
            return .init(scope: .top)
        case .computedProperty:
            return .init(scope: .top)
        case .none:
            return .init(scope: .top)
        }
    }
}

