# Native Claude context check, 2026-10-31

An isolated experiment with native Claude Code 2.1.316 reproduced a failed Sprava setup without a real
subscription token, personal Claude profile, or binder. A local mock Messages API returned the value of
`CURRENT_CHECK` found in the request's system prompt. All prompts, responses and credentials were invented.

The process used Sprava's sandbox, private HOME/config/tmp folders, safe/restricted mode, empty tools and
MCP, stream-json input/output, literal composed user messages, and an appended app-policy file. Only this
experiment supplied a loopback mock endpoint; production continues to reject inherited provider settings.

1. With a new native session and `CURRENT_CHECK=FIRST`, the request carried FIRST and returned FIRST.
2. After changing the policy file to SECOND and using `--resume` with the same native session, the request
   still carried FIRST and returned FIRST. Both native processes exited successfully.
3. With a fresh native session for each check, the requests carried FIRST then SECOND and returned those
   values. Both processes exited successfully.

Sprava's old verification required the second value to change within a resumed native session. That could
refuse a working account. Normal binder turns also refreshed only the appended system policy, allowing
native memory to retain an older source pack and task state.

The read/draft pilot now rebuilds each native turn from current scoped sources and authenticated saved app
history. The person's conversation persists in Sprava. Disposable native context is removed between turns;
it is not an authority or the only copy of anything the person wrote. This sacrifices native cache reuse
until a separately verified transport can safely refresh it.

The deterministic runtime fixture models the frozen system prompt on native resume. Its setup and
successive-turn tests require fresh native session ids, current app context, and unchanged app request
idempotency. Separate frame tests cover the current CLI's structured 401 authentication failures, including
`is_error: true` on a `subtype: success` result. No raw provider diagnostic reaches the app.
