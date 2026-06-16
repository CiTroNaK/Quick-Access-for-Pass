import Darwin
import Foundation

private func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return true }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(fd, baseAddress + offset, buffer.count - offset)
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

private func usage() -> Int32 {
    fputs("Usage: qa-env-export <output-path> <ENV_NAME> [ENV_NAME... ]\n", stderr)
    return 64
}

func main() -> Int32 {
    let args = CommandLine.arguments
    guard args.count >= 3 else { return usage() }

    let outputPath = args[1]
    let names = args.dropFirst(2)

    var output = Data()
    for name in names {
        guard let value = getenv(name) else { continue }
        output.append(contentsOf: name.utf8)
        output.append(UInt8(ascii: "="))
        output.append(contentsOf: String(cString: value).utf8)
        output.append(0)
    }

    let fd = open(outputPath, O_WRONLY)
    guard fd >= 0 else {
        fputs("Error: cannot open output channel\n", stderr)
        return 1
    }
    defer { close(fd) }

    guard writeAll(fd: fd, data: output) else {
        fputs("Error: cannot write output\n", stderr)
        return 1
    }

    return 0
}

exit(main())
