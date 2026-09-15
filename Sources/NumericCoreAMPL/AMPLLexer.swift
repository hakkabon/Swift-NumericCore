/// Lexer for the grammar in `docs/design/ampl-grammar.md`.
///
/// Hand-rolled rather than built on `hakkabon/Lexer` — see `Model.swift`'s
/// module docs for why. Token classes match the EBNF's terminals
/// directly: keyword, identifier, number, and the small fixed set of
/// symbols the grammar uses (`>=`, `<=`, `=`, `:=`, `+`, `-`, `:`, `;`, `,`).
enum TokenKind: Equatable {
    case keyword(String)
    case identifier(String)
    case number(Double)
    case symbol(String)
    case endOfInput
}

struct Token {
    let kind: TokenKind
    let position: Int
}

public enum LexError: Error, Equatable {
    case unexpectedCharacter(Character, position: Int)
}

private let amplKeywords: Set<String> = ["var", "param", "subject", "to", "minimize", "maximize"]

enum AMPLLexer {
    /// Tokenizes `source` in full, returning the token list terminated
    /// by a single `.endOfInput` token — the parser never needs to
    /// special-case "ran out of input" separately from "found the wrong
    /// token", since end-of-input is just another token to match against.
    static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0

        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func peekNext() -> Character? { i + 1 < chars.count ? chars[i + 1] : nil }

        while let c = peek() {
            if c.isWhitespace {
                i += 1
                continue
            }

            // Comments: "#" to end of line, matching AMPL's own convention.
            // Not in the EBNF (which only covers the statement grammar,
            // not lexical trivia) but necessary for any real model file.
            if c == "#" {
                while let c2 = peek(), c2 != "\n" { i += 1 }
                continue
            }

            let start = i

            if c.isLetter {
                var word = ""
                while let c2 = peek(), c2.isLetter || c2.isNumber || c2 == "_" {
                    word.append(c2)
                    i += 1
                }
                tokens.append(Token(kind: amplKeywords.contains(word) ? .keyword(word) : .identifier(word), position: start))
                continue
            }

            if c.isNumber || (c == "." && (peekNext()?.isNumber ?? false)) {
                var text = ""
                while let c2 = peek(), c2.isNumber {
                    text.append(c2)
                    i += 1
                }
                if peek() == "." {
                    text.append(".")
                    i += 1
                    while let c2 = peek(), c2.isNumber {
                        text.append(c2)
                        i += 1
                    }
                }
                // Guaranteed parseable: every character consumed above
                // is a digit or a single ".", per the loop conditions.
                tokens.append(Token(kind: .number(Double(text)!), position: start))
                continue
            }

            // Two-character symbols must be checked before their
            // single-character prefixes (":=" before ":", ">="/"<=" are
            // single tokens with no single-character prefix collision).
            if c == ":" && peekNext() == "=" {
                tokens.append(Token(kind: .symbol(":="), position: start))
                i += 2
                continue
            }
            if c == ">" && peekNext() == "=" {
                tokens.append(Token(kind: .symbol(">="), position: start))
                i += 2
                continue
            }
            if c == "<" && peekNext() == "=" {
                tokens.append(Token(kind: .symbol("<="), position: start))
                i += 2
                continue
            }

            if "=+-:;,".contains(c) {
                tokens.append(Token(kind: .symbol(String(c)), position: start))
                i += 1
                continue
            }

            throw LexError.unexpectedCharacter(c, position: start)
        }

        tokens.append(Token(kind: .endOfInput, position: chars.count))
        return tokens
    }
}
