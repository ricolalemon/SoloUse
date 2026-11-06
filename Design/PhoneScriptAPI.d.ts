/** Implemented in v0.10.0. Scripts use top-level await inside an async function.
 * Persist data in state/globalThis; function-local let/const are per invocation.
 * Since v0.11.0, scripts that change the UI after their last explicit observe
 * receive one final screenshot automatically. Its frame_id supersedes old stored
 * geometry. Inside the script, phone methods do not capture after every action.
 * Since v0.20.2, observation uses screenshots; readTree is no longer exposed.
 * Every phone call must be awaited sequentially. No filesystem/network/Node APIs.
 */
declare const state: Record<string, unknown>;
type Frame = { pending_paste_id?: string; clipboard_pending?: boolean; frame_id: string; width: number; height: number; orientation: string };
type Point = { x: number; y: number; frame_id: string };
declare const phone: {
  /** Screenshot is returned by default. emit:false returns metadata without emitting
   * pixels to the model; JS does not gain image understanding. Output retains the
   * newest images within a byte budget; omissions never stop code or erase state. */
  observe(args?: { emit?: boolean }): Promise<Frame>;
  listApps(args?: {}): Promise<{ apps: Array<{ id: string; name: string }> }>;
  openApp(args: { app_id: string }): Promise<{ opened: string }>;
  tap(args: Point): Promise<unknown>;
  doubleTap(args: Point): Promise<unknown>;
  longPress(args: Point & { duration_ms: number }): Promise<unknown>;
  swipe(args: Point & { end_x: number; end_y: number; duration_ms: number }): Promise<unknown>;
  /** Hardware keys; input method may transform characters. */
  typeText(args: { text: string }): Promise<unknown>;
  /** Requires a focused editable field. Does not submit. Inspect actual result. */
  pasteText(args: { text: string; replace_all: boolean }): Promise<{
    input_method: 'clipboard_paste'; characters: number; paste_id: string; clipboard_pending: true;
    verification_required: true;
  }>;
  /** Open the edit menu and observe first. Target its visible Paste control,
   * not the field. Uses current selection. Call finishPaste after verifying input. */
  pasteAt(args: Point & { text: string }): Promise<{
    input_method: 'clipboard_paste_control'; characters: number;
    paste_id: string; clipboard_pending: true; verification_required: true;
  }>;
  /** Verify insertion or dismiss the pending dialog before releasing the staged text. */
  finishPaste(args: { paste_id: string }): Promise<{
    clipboard_pending: false; clipboard_restored: boolean; newer_clipboard_preserved: boolean;
  }>;
  pressKey(args: { key: string }): Promise<unknown>;
  home(args?: {}): Promise<unknown>;
  wait(args: { milliseconds: number }): Promise<unknown>;
};
/** Verbose logs are truncated rather than terminating execution. */
declare function log(value: unknown): void;
/** At 64 phone operations a segment_complete result preserves state/globalThis,
 * but discards the pending operation and the remaining code. Use a new script to
 * continue from completed receipts. Nothing resumes or replays automatically.
 * CPU, memory, wall-time, cancellation and unknown-effect protections still apply.
 */
/** Ask for user input with a separate phone_ask_user call after the script ends.
 * A saved handoff preserves the model conversation, not JavaScript heap objects.
 */
