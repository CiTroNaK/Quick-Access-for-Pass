import Testing
@testable import Quick_Access_for_Pass

@Suite("RunSecretResolver.parseEnvOutput")
struct RunSecretResolverParseTests {

    @Test("parses plain key=value lines, filtering to requested keys")
    func parsesPlainLinesFilteredToRequestedKeys() {
        let output = """
            FOO=one
            BAR=two
            BAZ=three
            """
        let result = RunSecretResolver.parseEnvOutput(output, keys: ["FOO", "BAZ"])
        #expect(result == ["FOO": "one", "BAZ": "three"])
    }

    @Test("values containing `=` are preserved whole")
    func valuesContainingEqualsArePreserved() {
        let output = "TOKEN=abc=def=ghi"
        let result = RunSecretResolver.parseEnvOutput(output, keys: ["TOKEN"])
        #expect(result == ["TOKEN": "abc=def=ghi"])
    }

    @Test("lines without `=` are skipped silently")
    func malformedLinesAreSkipped() {
        let output = """
            GOOD=value
            this is not an env line
            ALSO_GOOD=another
            """
        let result = RunSecretResolver.parseEnvOutput(
            output,
            keys: ["GOOD", "ALSO_GOOD"]
        )
        #expect(result == ["GOOD": "value", "ALSO_GOOD": "another"])
    }

    @Test("empty output returns empty dictionary")
    func emptyOutputReturnsEmpty() {
        let result = RunSecretResolver.parseEnvOutput("", keys: ["FOO"])
        #expect(result.isEmpty)
    }

    @Test("empty value is preserved as empty string")
    func emptyValueIsPreserved() {
        let output = "FLAG="
        let result = RunSecretResolver.parseEnvOutput(output, keys: ["FLAG"])
        #expect(result == ["FLAG": ""])
    }
}
