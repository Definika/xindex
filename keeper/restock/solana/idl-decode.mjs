// An Anchor program's instruction read from its IDL (Anchor 0.30's format, which Jupiter's program publishes on chain),
// with no dependency, so the keeper's unit tests cover it (keeper/test/unit/restock-solana.test.mjs). The 8-byte
// discriminator names the instruction, and its arguments are read from the front, in order, as the program reads
// them. Reading from the front matters: a program ignores bytes after its last argument, so an argument found by
// counting back from the end could be a decoy appended after the real ones. An instruction carrying such bytes is
// refused outright.

function reader(bytes) {
  let at = 0;
  return {
    take(n) {
      if (at + n > bytes.length) throw new Error("the instruction ends inside its arguments");
      const slice = bytes.subarray(at, at + n);
      at += n;
      return slice;
    },
    get offset() {
      return at;
    },
  };
}

function readPrimitive(type, r) {
  switch (type) {
    case "bool": {
      const v = r.take(1)[0];
      if (v > 1) throw new Error(`a bool of ${v}`);
      return v === 1;
    }
    case "u8":
      return r.take(1)[0];
    case "i8":
      return r.take(1).readInt8(0);
    case "u16":
      return r.take(2).readUInt16LE(0);
    case "i16":
      return r.take(2).readInt16LE(0);
    case "u32":
      return r.take(4).readUInt32LE(0);
    case "i32":
      return r.take(4).readInt32LE(0);
    case "u64":
      return r.take(8).readBigUInt64LE(0);
    case "i64":
      return r.take(8).readBigInt64LE(0);
    case "u128":
    case "i128": {
      const s = r.take(16);
      const value = s.readBigUInt64LE(0) + (s.readBigUInt64LE(8) << 64n);
      return type === "i128" && value >= 1n << 127n ? value - (1n << 128n) : value;
    }
    case "pubkey":
    case "publicKey":
      return Buffer.from(r.take(32));
    case "bytes":
      return Buffer.from(r.take(r.take(4).readUInt32LE(0)));
    case "string":
      return r.take(r.take(4).readUInt32LE(0)).toString("utf8");
    default:
      throw new Error(`an IDL type this reader does not know: ${type}`);
  }
}

/// A struct's or a variant's fields: named (`[{name, type}]`), read as an object, or a tuple (`[type]`), as an array.
function readFields(fields, r, types) {
  if (!fields || fields.length === 0) return null;
  const named = typeof fields[0] === "object" && fields[0] !== null && "name" in fields[0];
  if (named) return Object.fromEntries(fields.map((f) => [f.name, read(f.type, r, types)]));
  return fields.map((t) => read(t, r, types));
}

function read(type, r, types) {
  if (typeof type === "string") return readPrimitive(type, r);
  if ("vec" in type) {
    const n = r.take(4).readUInt32LE(0);
    const out = [];
    for (let i = 0; i < n; i++) out.push(read(type.vec, r, types));
    return out;
  }
  if ("option" in type) {
    const tag = r.take(1)[0];
    if (tag > 1) throw new Error(`an option tag of ${tag}`);
    return tag === 0 ? null : read(type.option, r, types);
  }
  if ("array" in type) {
    const [inner, n] = type.array;
    return Array.from({ length: n }, () => read(inner, r, types));
  }
  if ("defined" in type) {
    const name = typeof type.defined === "string" ? type.defined : type.defined.name;
    const def = types.get(name);
    if (!def) throw new Error(`a type the IDL does not define: ${name}`);
    if (def.type.kind === "struct") return readFields(def.type.fields, r, types);
    if (def.type.kind === "enum") {
      const index = r.take(1)[0];
      const variant = def.type.variants[index];
      if (!variant) throw new Error(`variant ${index} of ${name}, which the IDL does not list`);
      return { [variant.name]: readFields(variant.fields, r, types) };
    }
    throw new Error(`a type kind this reader does not know: ${def.type.kind}`);
  }
  throw new Error(`an IDL type this reader does not know: ${JSON.stringify(type)}`);
}

/// Instruction `data` (bytes) of the program `idl` describes: `{name, args}`, its arguments by name (integers of 64 bits
/// or more as bigints, keys and byte strings as Buffers), or null when no instruction of the IDL has its
/// discriminator. Throws when the data ends inside the arguments or carries bytes after them.
export function decodeInstruction(idl, data) {
  const bytes = Buffer.from(data);
  if (bytes.length < 8) return null;
  const ix = idl.instructions.find((i) => Buffer.from(i.discriminator).equals(bytes.subarray(0, 8)));
  if (!ix) return null;
  const types = new Map((idl.types ?? []).map((t) => [t.name, t]));
  const r = reader(bytes.subarray(8));
  const args = {};
  for (const a of ix.args) args[a.name] = read(a.type, r, types);
  if (r.offset !== bytes.length - 8) throw new Error(`${ix.name} carries ${bytes.length - 8 - r.offset} bytes after its arguments`);
  return { name: ix.name, args };
}
