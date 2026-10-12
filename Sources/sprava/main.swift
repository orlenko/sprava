import BinderFormat
import BinderStore
import Foundation
import Services
import Shelf
import SpravaKit

// `sprava`: the read-only Shelf and Now pages of MVP increment 1 (docs/mvp.md section 5).
// Nothing here writes inside a binder. `shelf add` and `shelf remove` write only Sprava's own state.

let usage = """
usage: sprava shelf [--archived]          every binder: state, last change, overdue and Nudge counts
       sprava shelf add <folder>          add a folder to the shelf (Sprava's own state only)
       sprava shelf remove <folder>       take it off the shelf
       sprava now <folder> [--today YYYY-MM-DD]
                                          one binder's items in the eight buckets
       sprava check <folder>              the binder's state and rule findings (ids and counts only)
       sprava dashboard <folder> [--today YYYY-MM-DD]
                                          the DASHBOARD.md Sprava would write (read-only)
       sprava note <text> [--binder <name>] write a typed note as a capture event; without the app's
                                          notice its card is "unverified" and asks for a binder
       sprava clerk <text> [--locale <tag>] [--binder <name>=<description>]...
                                          developer only: run the on-device clerk on invented text and print
                                          what it read; nothing is filed
       sprava read-document <root> <relative-file> [--locale <tag>]
                                          developer only: read an invented file below an explicitly chosen root
                                          through the sandboxed helper when built beside this tool, then the
                                          clerk's document reading; prints facts, the reading and its items
       sprava clerk-gate <fixtures.json>   developer only: the clerk's release gate on invented fixtures:
                                          recall, dates, amounts, binders, calls and time
       sprava measures [--days N]          the shadow run's measures (mvp.md 1.2) over the last N days (30)
       sprava dev <command> <folder> ...  development only, on invented copies: adopt, proposals,
                                          approve <id>, reject <id>, complete <item-id>, drop <item-id>.
                                          Refuses any folder in lifeproj's registry or on Sprava's
                                          Shelf, or owned by the installed Sprava. Uses its own
                                          state and device id (the support folder plus "-dev").

The shelf lists new binders and folders added with `sprava shelf add`. lifeproj's registry
($CMIRROR_CONFIG or ~/.config/cmirror/config.toml) is listed only with "showRegistry": true in shelf.json.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()
switch command {
case "shelf": shelf(arguments)
case "now": now(arguments)
case "check": check(arguments)
case "dev": dev(arguments)
case "note": note(arguments)
case "dashboard":
    var args = arguments
    let day = todayFrom(&args)
    guard let path = args.first, let text = DashboardKeeper(folder: folderURL(path)).preview(today: day) else { fail(usage) }
    print(text, terminator: "")
case "clerk": clerk(arguments)
case "clerk-gate": clerkGate(arguments)
case "read-document": readDocument(arguments)
case "measures":
    let n = arguments.firstIndex(of: "--days").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 30
    let support = SpravaPaths.supportDirectory()
    let rows = ShelfStore(supportDirectory: support).rows()
    let end = CalendarDate.today()
    print(Measures.text(Measures(support: support).compute(rows: rows, from: end.adding(days: -(max(1, n) - 1)), to: end)), terminator: "")
case "-h", "--help", "help": print(usage)
default: fail(usage)
}
