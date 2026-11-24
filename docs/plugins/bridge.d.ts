// What a tool plugin's panel page can use, for editors and for Claude Code. Schema 1.
// Stability per member: @stable (kept compatible within schema 1), @experimental (may change in any
// release), @deprecated (still works, will go). The rules behind each are in reference.md.

/** The reply to a manifest command (Sources/cubi/Plugins/ToolBridge.swift, replyHandler). */
interface CubiCommandResult {
  /** @stable exit code 0 (for a `reveal` command: a non-empty path). */
  ok: boolean;
  /** @stable stdout as text (for a `reveal` command: the path, trimmed). */
  out: string;
  /** @stable stderr as text. */
  err: string;
}

/** `pick.file` / `pick.dir`: the native chooser. @experimental */
interface CubiPickResult {
  ok: boolean;
  /** "" when cancelled. */
  path: string;
  cancelled?: true;
}

/** `session.new`: open a Claude Code session; needs `"builtins": ["session.new"]`. @experimental */
interface CubiSessionNewResult {
  ok: boolean;
  err?: string;
  cancelled?: true;
}

/** The JSON passed as the one argument of `session.new`. Only these fields; any other is refused. @experimental */
interface CubiSessionNewSpec {
  directory: string;
  prompt?: string;
  restricted?: boolean;
  /** At most 8 existing folders; only with restricted. */
  readDirs?: string[];
  /** At most 4 commands marked `"sessionAllowed": true`; only with restricted. */
  allowActions?: string[];
}

/** JSON as the page gets it. */
type CubiJSON = null | boolean | number | string | CubiJSON[] | { [key: string]: CubiJSON };

/**
 * `service.call`: the service's `reply` (`ok`, `out` as it sent them, `err` ""), or why there is
 * none (`ok` false, `out` null, `err` a Chinese sentence). Never rejects. @experimental
 */
interface CubiServiceCallResult {
  ok: boolean;
  out: CubiJSON;
  err: string;
}

/** `service.state`: the last `state.data` the service sent; null before the first and once it has ended. @experimental */
type CubiServiceStateResult = { ok: true; state: { [key: string]: CubiJSON } | null } | { ok: false; err: string };

interface CubiBridge {
  /**
   * @stable Run a manifest command. Rejects (never resolves) when the action is not in the
   * manifest, the argument count or a type is wrong, or the plugin is switched off; the reason is
   * a Chinese sentence.
   */
  postMessage(message: { action: string; args: string[] }): Promise<CubiCommandResult>;
  /** @experimental Built-in native choosers. */
  postMessage(message: { action: "pick.file" | "pick.dir"; args?: string[] }): Promise<CubiPickResult>;
  /** @experimental args[0] is JSON.stringify(CubiSessionNewSpec); the user confirms every time. */
  postMessage(message: { action: "session.new"; args: [string] }): Promise<CubiSessionNewResult>;
  /**
   * @experimental Only with `service` in the manifest. args[0] is the action (a command name),
   * args[1] optional: JSON.stringify of an object, at most 16384 bytes. Waits 10 s at most.
   */
  postMessage(message: { action: "service.call"; args: [string] | [string, string] }): Promise<CubiServiceCallResult>;
  /** @experimental Only with `service` in the manifest. */
  postMessage(message: { action: "service.state"; args?: string[] }): Promise<CubiServiceStateResult>;
  /** @deprecated The old shape: name and value become args [name, value]. Use args. */
  postMessage(message: { action: string; name?: string; value?: string }): Promise<CubiCommandResult>;
}

/** One stretch of activity, epoch seconds. */
interface CubiSegment {
  start: number;
  end: number;
  /** The stretch still running. */
  open: boolean;
}

/** The session the panel was opened for (from a session's detail card). */
interface CubiSession {
  /** @stable */ id: string;
  /** @stable */ name: string;
  /** @stable absent when unknown */ cwd?: string;
  /** @stable absent when unknown */ projectDirectory?: string;
  /** @stable */ agent: string;
  /** @stable last 7 days */ segments: CubiSegment[];
}

interface Window {
  webkit?: {
    messageHandlers: {
      /** @stable `cubi` unless the manifest sets panel.bridge (@experimental). */
      [bridge: string]: CubiBridge;
    };
  };
  /** @stable Set before the page loads when opened from a session; replaced on a `cubisession` event. */
  cubiSession?: CubiSession;
  /**
   * @stable With `"panel": {"style": "cubi"}`: an SVG string for a line icon, "" for an unknown name.
   * Names: dashboard review settings play pause plus minus clock refresh external x check flag
   * target hourglass users sparkles download info link.
   */
  cubiIcon?: (name: string, size?: number) => string;
}

interface WindowEventMap {
  /** @stable The panel, already open, was handed another session: read window.cubiSession again. */
  cubisession: Event;
  /** @experimental The plugin's service sent a new `state` (`detail` is its `data`), or ended (`detail` null). */
  cubiservicestate: CustomEvent<{ [key: string]: CubiJSON } | null>;
}
