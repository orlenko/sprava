import BinderStore
import Brains
import Services

/// Invented records left by the retired installer; production app/CLI commands cannot mint them now.
@discardableResult
func legacyClient(_ commands: Commands, id: String, binders: [String: String], documents: Bool = false) throws -> String {
    var clients = try MCPClients.load(commands.support)
    let token = try clients.register(id: id, name: "Invented external client", binders: binders, documents: documents)
    try clients.save(commands.support)
    return token
}
