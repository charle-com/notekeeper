import Foundation
import NotekeeperCore

// Serveur MCP Notekeeper (stdio, JSON-RPC 2.0, une ligne par message).
//
//   notekeeper-mcp                        serveur MCP sur la base par défaut (ou NOTEKEEPER_DB)
//   notekeeper-mcp --db <chemin>          serveur MCP sur une base précise
//   notekeeper-mcp --seed-demo <chemin>   crée deux réunions de démonstration dans la base
//   notekeeper-mcp --demo-llm <chemin> [question]   essai bout en bout de l'assistant (LLM réel)
//   notekeeper-mcp --help

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> String {
    """
    Usage :
      notekeeper-mcp                          serveur MCP (stdio) sur la base par défaut ou $NOTEKEEPER_DB
      notekeeper-mcp --db <chemin>            serveur MCP sur la base indiquée
      notekeeper-mcp --seed-demo <chemin>     deux réunions de démonstration dans la base indiquée
      notekeeper-mcp --demo-llm <chemin> [q]  nameSpeakers, summarize, suggestTitle, catchUp, ask sur la première réunion
    """
}

func openStore(_ path: String?) -> Store? {
    let url: URL
    if let path, !path.isEmpty {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else if let env = ProcessInfo.processInfo.environment["NOTEKEEPER_DB"], !env.isEmpty {
        url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
    } else {
        url = Store.defaultURL()
    }
    do {
        return try Store(url: url)
    } catch {
        Log.info("base illisible (\(url.path)) : \(error.localizedDescription)")
        return nil
    }
}

var exitCode: Int32 = 0

switch arguments.first {
case "--help", "-h":
    print(usage())

case "--seed-demo":
    guard arguments.count >= 2, let store = openStore(arguments[1]) else {
        FileHandle.standardError.write(Data((usage() + "\n").utf8))
        exit(2)
    }
    do {
        let ids = try DemoSeed.seed(into: store)
        for id in ids {
            let m = try store.meeting(id)
            let n = try store.segments(meetingID: id).count
            print("\(id.uuidString)  \(m?.title ?? "?")  (\(n) tours de parole)")
        }
    } catch {
        Log.info("seed impossible : \(error.localizedDescription)")
        exitCode = 1
    }

case "--demo-llm":
    guard arguments.count >= 2, let store = openStore(arguments[1]) else {
        FileHandle.standardError.write(Data((usage() + "\n").utf8))
        exit(2)
    }
    let question = arguments.count >= 3 ? arguments[2...].joined(separator: " ") : nil
    exitCode = await DemoLLM.run(store: store, question: question)

case "--db":
    guard arguments.count >= 2, let store = openStore(arguments[1]) else {
        FileHandle.standardError.write(Data((usage() + "\n").utf8))
        exit(2)
    }
    MCPServer(store: store).run()

case .some(let unknown) where unknown.hasPrefix("-"):
    FileHandle.standardError.write(Data(("Option inconnue : \(unknown)\n" + usage() + "\n").utf8))
    exitCode = 2

default:
    guard let store = openStore(nil) else { exit(1) }
    MCPServer(store: store).run()
}

exit(exitCode)
