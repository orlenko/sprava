# A usable binder conversation and transcript sharing

Status: implementation handoff. Base: main `411fef71757e692d528d72f3f8251040ad4c4b3f`.

## Problem and outcome

The conversation is confined to a small scrolling region inside the binder's scrolling page. Reading a long
exchange or sharing it through screenshots is impractical. There is no obvious way to copy or save the thread.

Make conversation the binder's main working surface, using the available window height, and provide explicit
text sharing. Keep ordinary task/document controls directly accessible. This is a UI and transcript-access fix;
it does not implement the agent's missing filesystem tools or the broader design held in PR #531.

## Evidence and relevant code

- `Sources/SpravaApp/Binder/NowView.swift`: the binder's entire page is a `List`, including its conversation.
- `Binder/Chat/ChatView.swift`: its inner transcript `ScrollView` is constrained to min 160, ideal 340,
  max 460 points. Removing this maximum alone leaves the nested-scrolling layout problem unresolved.
- `Binder/Chat/ConversationSection.swift`: connection/sharing controls, thread, and suggested-task/draft cards.
- `Binder/BinderInputs.swift`: assistant first, with separately labelled deterministic to-do entry.
- `Binder/Chat/BinderChat.swift`: per-binder thread, draft, streaming, history and draft-close protection.
- `Binder/Chat/ClaudeBinderConversation.swift`: runtime adapter and structured reply cards.
- `Tests/SpravaAppTests/ConversationLayoutTests.swift`, `BinderChatTests.swift`,
  `ConversationResumeTests.swift`, `ClaudeConversationAdapterTests.swift`: existing behavior to preserve.
- `Sources/Services/Claude/ClaudeConversationRuntime.swift`: `chat_history` returns bounded saved turns and
  a `more` flag. It currently caps the response at 100 turns / 8 MiB.
- `Sources/BinderStore/ConversationTurnStore.swift`: canonical user lines and replies are in the runtime's
  `binder-store/conversation.sqlite`, outside binder folders. Use the app/runtime interface, not a UI SQLite reader.

## Layout

Use a simple binder-level Conversation / Project switch, with Conversation as the default for a connected
binder or one with saved conversation. The switch stays visible. Project retains direct to-dos, review cards,
filed documents, intake settings, history and binder details. Deterministic controls remain ordinary controls,
one click away; questions never become to-dos because Claude is unavailable.

The Conversation surface has a compact header, one flexible transcript scroller, and a composer anchored below
it. The thread gets the remaining height after actual header/composer needs, with no arbitrary 460-point ceiling.
Do not embed this surface in the Project list. A wide layout may add a resizable project pane later; that is not
required for this fix. Keep message lines comfortable to read rather than stretching them across a very wide window.

Keep Send, Stop and the current streaming/error state visible. The composer grows for several lines and then
scrolls within a sensible bound, so a long draft cannot consume the transcript. Keep setup/disconnection/error
states understandable; a disconnected binder still shows its history and any unsent draft.

Reuse the existing window-owned conversation/draft models. Changing view, resizing or switching binders must not
restart a conversation, stop a reply, duplicate a request, discard draft edits or turn off existing close guards.
Keep task and email-draft suggestions accessible in the Conversation surface, labelled by their originating turn.
Preserve their explicit confirmation/save behavior; changing layout grants no new action capabilities.

On opening a loaded thread or sending a message, show the latest exchange. While the reader is at the bottom,
follow a growing reply. If they scroll up, preserve that position while replies arrive and offer Jump to latest.
Do not scroll on every streamed update regardless of what the person is reading.

## Sharing

Add visible Copy conversation and Save transcript… actions to the conversation header. They work on the selected
binder's conversation, including messages outside the viewport, without sending another model request.

- Export readable UTF-8 plain text with You / Claude speaker labels and original line breaks/code indentation.
  Decode structured stored replies into their user-visible answer, not JSON envelopes.
- Include only this conversation's user-visible text/status. Exclude hidden prompts, provider frames, credential
  stores, source-document bodies not present in the exchange, and other binders. Unsent composer text stays out.
- Mark an incomplete or currently generating reply explicitly; exporting a snapshot must not claim it is complete.
- Copy uses the existing `ProtectedClipboard` convention, including its private/expiry behavior. Report copy failure
  without clearing the thread or draft. Saving uses a normal save panel with a generic `conversation.txt` default;
  cancellation does nothing. No upload, email, notification payload or content logging.
- Do not silently export only the on-screen viewport or treat the bounded history response as complete. Respect
  `more` and any UI history limits. For complete export, add bounded cursor pagination through the runtime if needed,
  with stable ordering and a clear snapshot boundary. Never bypass the runtime to read SQLite from the UI.
- If complete history cannot be obtained, say so. Any partial-copy option must be explicitly labelled as partial;
  never silently truncate or replace an unreadable saved history with an empty successful export.

## Acceptance and verification

Use invented fixtures only, including a generic instrument-workshop conversation. Do not read the author's actual
chat, binders, copied project files or credentials for implementation or test data.

1. Render at approximately 1024×768 and 1440×900. Conversation occupies the binder content area, grows with the
   window, and does not remain a small box within a second scrolling page. Check the narrow supported width too.
2. A long multi-turn exchange is readable with one transcript scrollbar. Composer and Send/Stop remain reachable.
   Resizing preserves draft text; a long draft cannot hide the thread completely.
3. Scroll upward during streaming: the viewport stays put. Jump to latest resumes following. Reopening saved history
   shows the newest exchange without a second empty input appearing for a disconnected binder.
4. Conversation / Project switching preserves an unsent message, a direct to-do draft, pending edits, and a running
   reply. Test switching between two binders: their messages, draft text and exports remain separate.
5. Copy/save a multi-turn thread larger than the viewport, with newlines, code and Unicode. Every selected turn appears
   once in order, with speaker labels. Test the history boundary beyond 100 turns and explicit partial-history errors.
6. Exporting does not send a model request, clear history, create tasks, or include hidden context or unsent text.
   Save cancellation and clipboard/write failure leave the conversation and drafts intact.
7. Exercise setup, disconnected-with-history, interrupted reply, runtime unavailable and suggested task/draft states.
   Preserve existing privacy/sharing/confirmation controls and normal draft-close protection.

Use native SwiftUI/AppKit rendered fixtures or the repository's native test workflow, not an HTML recreation.
Keep representative screenshots with invented content as review artifacts. Add regression tests for behavior this
change fixes; avoid tests that only restate layout constants. Run affected tests and packaging checks if packaging
changes. Follow the normal hook, final-head local Astra, single cloud-round and merge gates.

## Delivery and boundaries

Split at the natural seam if needed: (1) roomy Conversation / Project layout and (2) transcript sharing/history
pagination. Each PR must work independently and follow the repository's size/target rules. App-only layout should
not change a domain target. If export needs a domain interface, keep ownership in BinderStore with Services/app
adapters rather than spreading the feature across domain targets.

Do not merge #531, implement agent filesystem/network tools, import or delete live project files, re-enter an
account token, or claim the binder-management capability gap is solved by a larger chat window. Build/sign/install
only through the established separately coordinated workflow, preserving unsaved work. The author requested this
handoff because the laptop is shutting down; Gong can continue on Koza without waiting for more screenshots.
