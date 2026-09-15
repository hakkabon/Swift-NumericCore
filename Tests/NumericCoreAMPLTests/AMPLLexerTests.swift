import XCTest
@testable import NumericCoreAMPL

final class AMPLLexerTests: XCTestCase {
    func testTokenizesVarDeclaration() throws {
        let tokens = try AMPLLexer.tokenize("var x >= 0;")
        XCTAssertEqual(tokens.map(\.kind), [
            .keyword("var"), .identifier("x"), .symbol(">="), .number(0), .symbol(";"), .endOfInput,
        ])
    }

    func testTokenizesTwoCharacterSymbolsBeforeSinglePrefixes() throws {
        let tokens = try AMPLLexer.tokenize(":= >= <=")
        XCTAssertEqual(tokens.map(\.kind), [
            .symbol(":="), .symbol(">="), .symbol("<="), .endOfInput,
        ])
    }

    func testTokenizesDecimalNumber() throws {
        let tokens = try AMPLLexer.tokenize("3.14")
        XCTAssertEqual(tokens.map(\.kind), [.number(3.14), .endOfInput])
    }

    func testTokenizesSubjectToAsTwoKeywords() throws {
        let tokens = try AMPLLexer.tokenize("subject to capacity")
        XCTAssertEqual(tokens.map(\.kind), [
            .keyword("subject"), .keyword("to"), .identifier("capacity"), .endOfInput,
        ])
    }

    func testSkipsCommentsToEndOfLine() throws {
        let tokens = try AMPLLexer.tokenize("var x; # a trailing comment\nvar y;")
        XCTAssertEqual(tokens.map(\.kind), [
            .keyword("var"), .identifier("x"), .symbol(";"),
            .keyword("var"), .identifier("y"), .symbol(";"),
            .endOfInput,
        ])
    }

    func testThrowsOnUnrecognizedCharacter() {
        XCTAssertThrowsError(try AMPLLexer.tokenize("var x @ 0;")) { error in
            guard case LexError.unexpectedCharacter("@", _) = error else {
                return XCTFail("expected unexpectedCharacter, got \(error)")
            }
        }
    }

    func testIdentifierCanContainDigitsAndUnderscoresAfterFirstLetter() throws {
        let tokens = try AMPLLexer.tokenize("x_1")
        XCTAssertEqual(tokens.map(\.kind), [.identifier("x_1"), .endOfInput])
    }
}
