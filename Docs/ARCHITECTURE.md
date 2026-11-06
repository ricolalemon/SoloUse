# Architecture

```text
User task → Swift agent loop → remote model
                    ↓ tool calls
        Swift validation + QuickJS scripts
                    ↓
       Rust / idevice / local developer services
                    ↓
               iPhone apps
                    ↓
        receipts + screenshot → remote model
```

The execution loop and QuickJS runtime run on the iPhone. Model inference remains remote. The default control path uses CoreDevice services through LocalDevVPN (`10.7.0.1`); it does not use iPhone Mirroring or a Mac-side task runner. A Mac is currently needed for the documented build/signing and initial device preparation workflow.

`App/AgentCore` owns wire history, tool schemas, receipts, image references and compaction. `PhoneAgentModel` coordinates UI, checkpoints and model/phone sessions. `ScriptExecutor` exposes a small asynchronous JavaScript API; it does not expose Node.js, a shell, arbitrary file access or network fetch. [Script interface](../Design/PhoneScriptAPI.d.ts).

`Native/src` provides pairing, the local tunnel, image transfer, HID input, clipboard leases and command receipts. The optional `TreeRunner` is a read-only XCTest diagnostic component. It is not required or exposed by the default agent; installing it alone does not enable tree-based model operation.

Full conversations and cached receipts refer to per-chat content-addressed images. Active input normally retains up to eight images within an 8 MB image window; older images are discoverable through history tools. Automatic compaction changes active model input, not the full archive. After compaction the next model may need a fresh observation. Availability of stored history is not proof that every semantic fact survived model compaction.

Before dispatch and after tool completion, a rolling recovery manifest is saved atomically. A mid-call interruption becomes an uncertain receipt; queued calls are not restarted. Relaunch displays the record and waits for explicit continuation. JavaScript variables and program counters do not survive process loss; old frame IDs are invalid.

Media startup persists a session UUID before requesting streams. A subsequent run only reclaims a stream when every reported owner matches that private marker, then verifies shutdown. Foreign or unidentified streams remain blocked. Legacy streams without a marker may need manual cleanup.
