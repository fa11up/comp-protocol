#!/usr/bin/env node
// Derives a feed's pinned question-document prefix from the oracle payload it will be fed.
//
//   node oracle/question-prefix.mjs <payload.json> [--verify <oracleRequestId>]
//
// WHY THIS EXISTS. A feed verifies WHICH question an attestation answers by rebuilding the
// control plane's question document and comparing keccak against the signed questionHash. The
// document is (packages/protocol/src/schemas/oracle.ts, questionDocument):
//
//   { v, question, chainId, window: {fromBlock, toBlock}, answerType, head?, definitions?, evidence? }
//
// canonicalised as an RFC 8785 (JCS) subset: object keys sorted by UTF-16 code unit, JSON string
// escaping, integers only. Because the keys are sorted, "window" sorts LAST, so the only part that
// changes between two otherwise identical requests is a SUFFIX:
//
//   <PREFIX>{fromBlock}," toBlock":{toBlock}}}      (no space; see the emitted constant)
//
// The feed therefore pins PREFIX and splices in the attestation's own signed fromBlock/toBlock.
//
// Everything request-specific MUST stay out of the document, because the document is hashed:
// guards, panelSize, quorum, toleranceBps and consumer are all excluded by questionDocument, so a
// moving price band belongs in `guards`, never in `definitions`.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const canon = (v) => {
  if (v === null) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") {
    if (!Number.isFinite(v)) throw new Error("non-finite number");
    if (!Number.isInteger(v)) throw new Error("non-integer number");
    return JSON.stringify(v === 0 ? 0 : v);
  }
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canon).join(",")}]`;
  if (typeof v === "object") {
    const keys = Object.keys(v).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(",")}}`;
  }
  throw new Error(`unsupported ${typeof v}`);
};

const PROTOCOL_VERSION = 1;

// Mirrors questionDocument exactly, including that `evidence` appears ONLY for "panel" — a chain
// request omits it, which is how every hash issued before the field existed still holds.
const questionDocument = (input, window) => ({
  v: PROTOCOL_VERSION,
  question: input.question,
  chainId: input.chainId,
  window: { fromBlock: window.fromBlock, toBlock: window.toBlock },
  answerType: input.answerType,
  ...(input.head !== undefined ? { head: input.head } : {}),
  ...(input.definitions ? { definitions: input.definitions } : {}),
  ...(input.evidence === "panel" ? { evidence: "panel" } : {}),
});

const hex = (b) => Buffer.from(b).toString("hex");
// keccak256 via foundry rather than a new dependency: execFileSync passes the argument with no
// shell, so a document full of quotes and braces needs no escaping.
const keccakUtf8 = (s) =>
  execFileSync("cast", ["keccak", s], { encoding: "utf8" }).trim().replace(/^0x/, "");

const [payloadPath, ...rest] = process.argv.slice(2);
if (!payloadPath) {
  console.error("usage: node oracle/question-prefix.mjs <payload.json> [--verify <oracleRequestId>]");
  process.exit(1);
}
const input = JSON.parse(readFileSync(payloadPath, "utf8")).input;

// Any window produces the same prefix; these two only locate the splice point.
const doc = questionDocument(input, { fromBlock: 1, toBlock: 2 });
const serialized = canon(doc);
const marker = ',"window":{"fromBlock":';
const at = serialized.indexOf(marker);
if (at < 0) throw new Error("window key not found — canonicalisation changed");
const prefix = serialized.slice(0, at + marker.length);

// Prove the splice reproduces the whole document before emitting anything.
const rebuilt = `${prefix}1,"toBlock":2}}`;
if (rebuilt !== serialized) throw new Error("splice does not reproduce the document");

const verifyIdx = rest.indexOf("--verify");
if (verifyIdx >= 0) {
  const id = rest[verifyIdx + 1];
  const r = await fetch(`https://api.imd.fun/oracle/requests/${id}`);
  if (!r.ok) throw new Error(`request ${id}: HTTP ${r.status}`);
  const live = await r.json();
  const spliced = `${prefix}${live.window.fromBlock},"toBlock":${live.window.toBlock}}}`;
  const got = `0x${keccakUtf8(spliced)}`;
  const ok = got.toLowerCase() === live.questionHash.toLowerCase();
  console.error(`verify ${id}: ${ok ? "MATCH" : "MISMATCH"}`);
  console.error(`  computed ${got}`);
  console.error(`  live     ${live.questionHash}`);
  if (!ok) {
    console.error("  the payload's question/definitions differ from that request's, or the");
    console.error("  canonicalisation changed. Do NOT pin this prefix.");
    process.exit(1);
  }
}

console.error(`prefix: ${prefix.length} bytes; full document ${serialized.length} bytes`);
console.error(`prefix tail: ${JSON.stringify(prefix.slice(-44))}`);
// Emitted as a hex literal, never as a Solidity string: the question contains quotes and braces,
// and a hand-transcribed 2 KB literal is a defect waiting to happen.
console.log(`    bytes internal constant QUESTION_PREFIX = hex"${hex(Buffer.from(prefix, "utf8"))}";`);
