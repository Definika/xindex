// The request loop every chain's signer runs (`solana/signer.mjs`, `sui/signer.mjs`, ...), with no dependency: one
// JSON request per line on stdin, `{id, op, args}`, answered on stdout, `{id, ok, result}` or `{id, ok: false,
// error}`, one at a time, in order. `moves` maps each request's name to its function. A signer first routes the console
// to stderr, before it loads any library, since stdout carries only answers (`quietConsole`).

/// Sends everything a library prints to stderr. Called first thing, before any library loads.
export function quietConsole() {
  for (const name of ["log", "info", "debug", "warn"]) console[name] = (...args) => console.error(...args);
}

/// The value of setting `name`, which must be set.
export function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

/// Answers requests for `moves` until stdin ends; `ready` is the first answer (id 0).
export function serve(moves, ready) {
  const answer = (message) => process.stdout.write(`${JSON.stringify(message, (_, v) => (typeof v === "bigint" ? v.toString() : v))}\n`);
  let queue = Promise.resolve();
  let buffer = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      queue = queue.then(async () => {
        let id = null;
        try {
          const request = JSON.parse(line);
          id = request.id;
          const op = Object.hasOwn(moves, request.op) ? moves[request.op] : null;
          if (typeof op !== "function") throw new Error(`no such request: ${request.op}`);
          answer({ id, ok: true, result: await op(request.args ?? {}) });
        } catch (error) {
          answer({ id, ok: false, error: String(error?.message ?? error) });
        }
      });
    }
  });
  process.stdin.on("end", () => queue.then(() => process.exit(0)));
  answer({ id: 0, ok: true, result: { ready: true, ...ready } });
}
