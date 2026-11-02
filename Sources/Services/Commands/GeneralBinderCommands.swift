import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

extension Commands {
    /// D26: create only on first explicit use, from the bundled blank template, without reading a registry.
    func generalBinder(_ request: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        guard let path = request["parent"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
            throw Failure(message: "General needs an absolute binders folder.")
        }
        let shelf = ShelfStore(supportDirectory: support)
        let picked = try shelf.readFolders()
        let known = Shelf.rows(registry: nil, picked: picked).map(\.name)
        let folder = try GeneralBinder(support: support).ensure {
            let parent = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            // The app requests this only for its fresh-install default or an explicitly chosen location.
            if request["create_parent"] == .bool(true) {
                _ = try StateDirectory.open(parent, create: true)
            }
            let name = BinderCreator.freeName("general", parent: parent, knownNames: known)
            return try BinderCreator.create(parent: parent, name: name, template: TemplateLibrary.bundled("blank"),
                                            deviceID: deviceID, knownNames: known, year: today.year, today: today, now: now).folder
        }
        let teka = Teka.read(folder)
        guard teka.isAdopted, !teka.writesBlocked, Self.ownerDevice(of: folder) == deviceID else {
            throw Failure(message: "General cannot take changes. Check its binder page and restore or repair its original folder.")
        }
        // Retrying after a lost reply or a failed Shelf write registers the same committed folder.
        try shelf.add(folder)
        return JSONObject([(key: "binder", value: .string(folder.path))])
    }

    /// Must run before app lifecycle owners: stopping a conversation can already discard its history.
    public func generalRetirementRefusal(_ text: String) -> String? {
        guard let request = try? JSONParser.parse(text).value.objectValue else { return nil }
        do { try checkGeneralRetirement(request); return nil }
        catch { return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .string("\(error)"))])) }
    }

    func checkGeneralRetirement(_ request: JSONObject) throws {
        let command = request["command"]?.stringValue
        guard command == "shelf_remove" || command == "transfer" ||
                (command == "backup_request" && request["kind"] == .str("offload")) else { return }
        let protected: Bool
        do { protected = try GeneralBinder(support: support).protects(try folder(request)) }
        catch { throw Failure(message: "General's record could not be checked. Nothing was removed, transferred or offloaded. Repair its record first.") }
        if protected { throw Failure(message: "General stays on this Mac's Shelf. It cannot be removed, transferred or offloaded; its ordinary backups still work.") }
    }
}
