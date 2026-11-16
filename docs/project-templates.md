# Project templates

Sprava organizes any personal project. Project categories are editable template folders, not Swift cases.
In Settings, **Open Templates Folder** opens the library. A fresh installation gets copies of the shipped
examples once; later edits and deletions are preserved. Copy a folder and give it a new key to add a template.
New Binder reads the library afresh and previews the description, folders, checklist, full project guide and
starting instructions.

Each folder contains `template.json` and `PROJECT.md`, and may contain `instructions.md`. For example, an
invented instrument workshop:

```json
{
  "version": 1,
  "key": "instrument-workshop",
  "title": "Instrument workshop",
  "summary": "Purchase, condition, repairs and resale",
  "name": "",
  "folders": ["inventory", "condition", "repairs", "sales"],
  "checklist": ["Record purchase evidence", "Record observed condition"]
}
```

The folder name must equal `key`: lowercase letters, digits and hyphens. `name` is an optional initial
suggestion; an empty string asks the person to name the project. An optional `yearLabel` enables a year
field, and `{year}` in the name, summary and guide is replaced with that year. `isDefault: true` marks the
initial choice; at most one template may be the default. There are no inferred statutory deadlines.

`PROJECT.md` contains the project's purpose, filing conventions, research/search guidance, source and
citation requirements, and drafting rules. These are the project's own editable material. They never grant
permission to widen sharing, read another binder, execute a hook, or perform an outward action.

An optional `instructions.md` holds a starting text for the new binder's instructions (binder-instructions.md
§5): the few operative rules on where documents go, how they are named and what becomes a to-do. It is at most
16,000 characters and 64 KiB and holds none of Sprava's marker lines. An invented example:

```
This binder holds an instrument workshop's records.
- Repair invoices go in repairs; name them "<instrument> <yyyy-mm-dd>".
- Only a payment someone asks for by a date becomes a to-do.
```

Creation makes the listed folders, `intake/`, a visible `PROJECT.md` listed among the binder's documents,
and an undated checklist card to review. A template with `instructions.md` also writes it as the binder's
`AGENTS.md`, accepted for filing since the person saw it in the preview; one without writes no `AGENTS.md`.
The binder keeps a manifest snapshot in `.sprava/template.json` and the selected template's fingerprint,
which covers `instructions.md` when there is one, in its metadata. Editing the library affects future
binders; each existing binder retains its own guide and instructions and can develop independently. The
read/draft pilot's guide is shared as a document only with document consent; its operation and permission
limits remain in force.

Templates are bounded data: no executable files, hooks or arbitrary file copying. Folder escapes, reserved
state-file collisions, symbolic links and malformed templates are refused. If a library is empty, New
Binder asks for a template rather than inventing or restoring a project type. The app's runtime owns the
library under `binder-store/templates/` in its support folder; all examples shipped here are invented.
