import Foundation

struct SwiftBuildCommand: Decodable {
    let moduleName: String
    let isLibrary: Bool
    let sources: [String]
    let objects: [String]
    let otherArguments: [String]
    let importPath: String
}

struct SwiftBuildPlan: Decodable {
    let swiftCommands: [String: SwiftBuildCommand]
}

struct ManifestCommand: Decodable {
    let tool: String
    let outputs: [String]
    let args: [String]?
}

struct LinkBuildPlan: Decodable {
    let commands: [String: ManifestCommand]
}

enum CodeQLBuildError: Error {
    case invalidPlan(String)
    case compilerExit(Int32)
    case schemaFailure(String, DecodingError)
    case ioFailure(String, NSError)
}

func readBoundedFile(_ path: String, _ operation: String) throws -> Data {
    let url: URL = URL(fileURLWithPath: path)
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: [.fileSizeKey])
    } catch let error as NSError {
        throw CodeQLBuildError.ioFailure(operation, error)
    }
    guard let size: Int = values.fileSize,
          size > 0, size <= 10 * 1024 * 1024 else {
        throw CodeQLBuildError.invalidPlan("Plan input must be nonempty and at most 10 MiB")
    }
    do {
        return try Data(contentsOf: url)
    } catch let error as NSError {
        throw CodeQLBuildError.ioFailure(operation, error)
    }
}

func safeSchemaPath(_ keys: [any CodingKey]) -> String {
    let fieldNames: Set<String> = ["swiftCommands", "commands", "moduleName", "isLibrary", "sources", "objects", "otherArguments", "importPath", "tool", "outputs", "args"]
    let components: [String] = keys.prefix(8).map { key in
        if let index: Int = key.intValue {
            return index >= 0 && index <= 1000 ? "[\(index)]" : "[index]"
        }
        return fieldNames.contains(key.stringValue) ? key.stringValue : "<entry>"
    }
    return components.isEmpty ? "$" : "$." + components.joined(separator: ".")
}

func schemaFailureDetails(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, let context):
        return "missing_field path=" + safeSchemaPath(context.codingPath + [key])
    case .typeMismatch(_, let context):
        return "type_mismatch path=" + safeSchemaPath(context.codingPath)
    case .valueNotFound(_, let context):
        return "missing_value path=" + safeSchemaPath(context.codingPath)
    case .dataCorrupted(let context):
        return "invalid_data path=" + safeSchemaPath(context.codingPath)
    @unknown default:
        return "unsupported_decoding_case; inspect the supported Foundation decoder contract"
    }
}

func validateBuildPath(_ path: String, _ root: String) throws {
    let url: URL = URL(fileURLWithPath: path)
    let rootURL: URL = URL(fileURLWithPath: root)
    guard url.standardizedFileURL.path == path,
          url.resolvingSymlinksInPath().path.hasPrefix(rootURL.resolvingSymlinksInPath().path + "/") else {
        throw CodeQLBuildError.invalidPlan("A consumed build path escapes its expected root")
    }
}

func selectedModule(_ plan: SwiftBuildPlan, _ name: String) throws -> SwiftBuildCommand {
    let matches: [SwiftBuildCommand] = plan.swiftCommands.values.filter { $0.moduleName == name }
    guard matches.count == 1 else {
        throw CodeQLBuildError.invalidPlan("Expected exactly one build command for the required module")
    }
    return matches[0]
}

func validateStrings(_ values: [String], _ maximumCount: Int) throws {
    guard !values.isEmpty, values.count <= maximumCount,
          values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 && !$0.contains("\0") }) else {
        throw CodeQLBuildError.invalidPlan("Plan string array violates count or string bounds")
    }
}

func compilerArguments(_ swiftPlan: SwiftBuildPlan, _ linkPlan: LinkBuildPlan,
                       _ inventory: Data, _ workspace: String, _ binPath: String,
                       _ compiler: String, _ sdk: String) throws -> [String] {
    guard swiftPlan.swiftCommands.count <= 100, linkPlan.commands.count <= 1000,
          let inventoryText: String = String(data: inventory, encoding: .utf8) else {
        throw CodeQLBuildError.invalidPlan("Plan count or UTF-8 source inventory is invalid")
    }
    let ownedPaths: [String] = inventoryText.split(separator: "\0").map(String.init).filter { $0.hasSuffix(".swift") }
    try validateStrings(ownedPaths, 1000)
    guard ownedPaths.allSatisfy({ $0.hasPrefix("Sources/DriveCore/") || $0.hasPrefix("Sources/DriveTrace/") }),
          !ownedPaths.contains(where: { $0.split(separator: "/").contains("..") }) else {
        throw CodeQLBuildError.invalidPlan("Source inventory is outside the production targets")
    }
    let expectedCore: Set<String> = Set(ownedPaths.filter { $0.hasPrefix("Sources/DriveCore/") }.map { workspace + "/" + $0 })
    let expectedApp: Set<String> = Set(ownedPaths.filter { $0.hasPrefix("Sources/DriveTrace/") }.map { workspace + "/" + $0 })
    let core: SwiftBuildCommand = try selectedModule(swiftPlan, "DriveCore")
    let app: SwiftBuildCommand = try selectedModule(swiftPlan, "DriveTrace")
    try validateStrings(core.sources, 1000)
    try validateStrings(core.objects, 1000)
    try validateStrings(core.otherArguments, 512)
    try validateStrings(app.sources, 1000)
    try validateStrings(app.otherArguments, 512)
    for command in [core, app] {
        for pair in [("-target", "arm64-apple-macosx14.0"), ("-sdk", sdk), ("-swift-version", "6"), ("-package-name", "drivetrace")] {
            guard command.otherArguments.filter({ $0 == pair.0 }).count == 1,
                  let index: Int = command.otherArguments.firstIndex(of: pair.0), index + 1 < command.otherArguments.count,
                  command.otherArguments[index + 1] == pair.1 else {
                throw CodeQLBuildError.invalidPlan("Native architecture, SDK, Swift or package flags changed")
            }
        }
    }
    let accessor: String = binPath + "/DriveTrace.build/DerivedSources/resource_bundle_accessor.swift"
    guard !expectedCore.isEmpty, !expectedApp.isEmpty,
          core.isLibrary, !app.isLibrary,
          Set(core.sources) == expectedCore, core.sources.count == expectedCore.count,
          Set(app.sources) == expectedApp.union([accessor]), app.sources.count == expectedApp.count + 1,
          core.objects.count == expectedCore.count,
          Set(core.objects).count == expectedCore.count,
          core.objects.allSatisfy({ $0.hasPrefix(binPath + "/DriveCore.build/") && $0.hasSuffix(".o") }),
          core.importPath == binPath + "/Modules", app.importPath == core.importPath,
          !app.otherArguments.contains(where: { $0.hasPrefix("-emit-") || $0 == "-c" || $0 == "-output-file-map" }) else {
        throw CodeQLBuildError.invalidPlan("Production source, object, module or executable-output contract changed")
    }
    let binary: String = binPath + "/DriveTrace"
    let matches: [ManifestCommand] = linkPlan.commands.values.filter { $0.tool == "shell" && $0.outputs == [binary] }
    guard matches.count == 1, let linkArguments: [String] = matches[0].args else {
        throw CodeQLBuildError.invalidPlan("Expected exactly one native executable linker command")
    }
    try validateStrings(linkArguments, 512)
    for pair in [("-target", "arm64-apple-macosx14.0"), ("-sdk", sdk)] {
        guard linkArguments.filter({ $0 == pair.0 }).count == 1,
              let index: Int = linkArguments.firstIndex(of: pair.0), index + 1 < linkArguments.count,
              linkArguments[index + 1] == pair.1 else {
            throw CodeQLBuildError.invalidPlan("Native executable link architecture or SDK flags changed")
        }
    }
    let objectList: String = "@" + binPath + "/DriveTrace.product/Objects.LinkFileList"
    guard linkArguments.first == compiler,
          linkArguments.filter({ $0 == objectList }).count == 1,
          linkArguments.filter({ $0 == "-o" }).count == 1,
          let outputIndex: Int = linkArguments.firstIndex(of: "-o"), outputIndex + 1 < linkArguments.count,
          linkArguments[outputIndex + 1] == binary,
          linkArguments.contains("-emit-executable"),
          !linkArguments.contains(where: { $0.hasPrefix("-emit-module") || $0 == "-c" }) else {
        throw CodeQLBuildError.invalidPlan("Linker compiler, response file or executable mode changed")
    }
    let executableArguments: [String] = Array(linkArguments.dropFirst()).flatMap { argument in
        argument == objectList ? core.objects + app.sources : [argument]
    }
    return ["-I", app.importPath] + app.otherArguments + executableArguments
}

/// Compiler execution is bounded by the enclosing Actions job's 45-minute deadline.
func runBuild(_ arguments: [String]) throws {
    guard arguments.count == 7 else {
        throw CodeQLBuildError.invalidPlan("Expected Swift plan, link plan, inventory, workspace, bin path, compiler and SDK")
    }
    let decoder: JSONDecoder = JSONDecoder()
    let swiftData: Data = try readBoundedFile(arguments[0], "read SwiftPM compiler plan")
    let swiftPlan: SwiftBuildPlan
    do {
        swiftPlan = try decoder.decode(SwiftBuildPlan.self, from: swiftData)
    } catch let error as DecodingError {
        throw CodeQLBuildError.schemaFailure("decode SwiftPM compiler plan", error)
    }
    let linkData: Data = try readBoundedFile(arguments[1], "read native executable link plan")
    let linkPlan: LinkBuildPlan
    do {
        linkPlan = try decoder.decode(LinkBuildPlan.self, from: linkData)
    } catch let error as DecodingError {
        throw CodeQLBuildError.schemaFailure("decode native executable link plan", error)
    }
    let inventory: Data = try readBoundedFile(arguments[2], "read production source inventory")
    let compileArguments: [String] = try compilerArguments(swiftPlan, linkPlan, inventory, arguments[3], arguments[4], arguments[5], arguments[6])
    let core: SwiftBuildCommand = try selectedModule(swiftPlan, "DriveCore")
    let app: SwiftBuildCommand = try selectedModule(swiftPlan, "DriveTrace")
    let accessor: String = arguments[4] + "/DriveTrace.build/DerivedSources/resource_bundle_accessor.swift"
    for path in core.objects + app.sources {
        try validateBuildPath(path, path == accessor || core.objects.contains(path) ? arguments[4] : arguments[3])
        let values: URLResourceValues
        do {
            values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])
        } catch let error as NSError {
            throw CodeQLBuildError.ioFailure("inspect required build file", error)
        }
        guard values.isRegularFile == true else {
            throw CodeQLBuildError.invalidPlan("A required compiled Core object or app source is missing")
        }
    }
    try validateBuildPath(arguments[4] + "/DriveTrace", arguments[4])
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[5])
    process.arguments = compileArguments
    do {
        try process.run()
    } catch let error as NSError {
        throw CodeQLBuildError.ioFailure("start direct Swift compiler", error)
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw CodeQLBuildError.compilerExit(process.terminationStatus)
    }
    print("Direct Swift executable build covered both complete production targets and the generated resource accessor.")
}

do {
    try runBuild(Array(CommandLine.arguments.dropFirst()))
} catch CodeQLBuildError.invalidPlan(let reason) {
    FileHandle.standardError.write(Data("CodeQL build plan rejected: \(reason).\n".utf8))
    exit(1)
} catch CodeQLBuildError.compilerExit(let status) {
    FileHandle.standardError.write(Data("Direct Swift compiler failed with status \(status); inspect the build diagnostics.\n".utf8))
    exit(1)
} catch CodeQLBuildError.schemaFailure(let operation, let error) {
    FileHandle.standardError.write(Data("CodeQL plan schema failed: operation=\(operation) \(schemaFailureDetails(error)); inspect the consumed plan schema.\n".utf8))
    exit(1)
} catch CodeQLBuildError.ioFailure(let operation, let error) {
    FileHandle.standardError.write(Data("CodeQL plan I/O failed: operation=\(operation) domain=\(error.domain) code=\(error.code).\n".utf8))
    exit(1)
}
