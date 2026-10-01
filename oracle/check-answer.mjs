#!/usr/bin/env node
/**
 * Checks `artifacts/answer.json` against the brief before it is submitted.
 *
 * The plane refuses an answer for a formality without reading its figure: a recipe kind it does
 * not know, a note over the size limit, a window copied wrong, an address in checksum case. Each
 * refusal cost a seat and, in a panel of four, sometimes the question. Every rule here is the
 * plane's own, so an answer that passes is an answer that is read.
 *
 *   node .imd/reads/skills/oracle-assess/scripts/check-answer.mjs [artifacts/answer.json] [.imd/reads/oracle.json]
 *
 * Exit 0 and "ok" when nothing is wrong; exit 1 with one line per problem otherwise.
 */
import { readFileSync } from "node:fs";

const [answerPath = "artifacts/answer.json", briefPath = ".imd/reads/oracle.json"] = process.argv.slice(2);
const MAX_BYTES = 16_000;
const KINDS = {
  panel: { required: ["source"], optional: [] },
  "log-sum": { required: ["address", "event", "sumArg", "abs"], optional: ["filter"] },
  "log-rank": { required: ["address", "event", "sumArg", "abs", "groupBy", "topN"], optional: [] },
  "call-compare": { required: ["to", "function", "args", "op", "threshold"], optional: [] },
  "v4-volume-rank": { required: ["poolManager", "token", "initializedSince", "topN"], optional: ["yield", "exclude"] },
};
const isAddress = (v) => typeof v === "string" && /^0x[0-9a-f]{40}$/.test(v);
const isBytes32 = (v) => typeof v === "string" && /^0x[0-9a-f]{64}$/.test(v);
const isUint = (v) => typeof v === "string" && /^(0|[1-9][0-9]*)$/.test(v) && BigInt(v) < 1n << 256n;
const isArg = (v) => typeof v === "string" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(v) && v.length <= 64;

export function problemsOf(answer, brief, bytes) {
  const problems = [];
  const say = (text) => problems.push(text);
  if (bytes > MAX_BYTES) say(`the file is ${bytes} bytes; the plane reads at most ${MAX_BYTES}. Shorten notes.`);
  if (typeof answer !== "object" || answer === null || Array.isArray(answer)) return [...problems, "answer.json must be one JSON object"];
  const allowed = new Set(["v", "requestId", "chainId", "window", "answerType", "answer", "figure", "definitions", "recipe", "notes"]);
  for (const key of Object.keys(answer)) if (!allowed.has(key)) say(`unknown top-level field "${key}"`);
  if (answer.v !== 1) say("v must be 1");
  if (brief) {
    if (answer.requestId !== brief.requestId) say(`requestId must be ${brief.requestId} (copied from the brief), not ${JSON.stringify(answer.requestId)}`);
    if (answer.chainId !== brief.chainId) say(`chainId must be ${brief.chainId}, not ${JSON.stringify(answer.chainId)}`);
    if (JSON.stringify(answer.window) !== JSON.stringify(brief.window)) say(`window must be exactly ${JSON.stringify(brief.window)}, not ${JSON.stringify(answer.window)}`);
    if (answer.answerType !== brief.answerType) say(`answerType must be ${brief.answerType}, the type the request asked for, not ${JSON.stringify(answer.answerType)}`);
  }
  const type = brief?.answerType ?? answer.answerType;
  const value = answer.answer;
  const typeOk = {
    bool: () => typeof value === "boolean",
    address: () => isAddress(value),
    bytes32: () => isBytes32(value),
    uint256: () => isUint(value),
    "address[]": () => Array.isArray(value) && value.length <= 32 && value.every(isAddress),
    "bytes32[]": () => Array.isArray(value) && value.length <= 32 && value.every(isBytes32),
  }[type];
  if (!typeOk) say(`answerType ${JSON.stringify(type)} is not one of bool, address, bytes32, uint256, address[], bytes32[]`);
  else if (!typeOk()) say(`answer ${JSON.stringify(value)?.slice(0, 80)} is not a ${type} (lowercase hex; a uint256 is a decimal string; a list has at most 32 entries)`);
  const head = Math.max(1, brief?.head ?? 1);
  if (Array.isArray(value) && value.length < head) say(`a ${type} answer needs at least ${head} entries; this one has ${value.length}. An empty list is not an answer.`);
  if (answer.figure !== undefined && !isUint(answer.figure)) say("figure must be a decimal string (a uint256) or left out");
  if (answer.definitions !== undefined) {
    if (typeof answer.definitions !== "object" || answer.definitions === null || Array.isArray(answer.definitions)) say("definitions must be an object of short strings");
    else for (const [k, v] of Object.entries(answer.definitions)) {
      if (k.length > 64) say(`definition key "${k.slice(0, 20)}…" is over 64 characters`);
      if (typeof v !== "string" || v.length === 0 || v.length > 512) say(`definition "${k}" must be a string of 1 to 512 characters`);
    }
  }
  if (answer.notes !== undefined && (typeof answer.notes !== "string" || answer.notes.length > 4000)) say("notes must be a string of at most 4000 characters");
  const recipe = answer.recipe;
  if (typeof recipe !== "object" || recipe === null) say("recipe is required");
  else {
    const spec = KINDS[recipe.kind];
    if (!spec) say(`recipe.kind ${JSON.stringify(recipe.kind)} is not in the catalogue: ${Object.keys(KINDS).join(", ")}. Only these can be rerun; describe how you computed in notes instead.`);
    else {
      for (const key of spec.required) if (!(key in recipe)) say(`recipe.${key} is required for ${recipe.kind}`);
      for (const key of Object.keys(recipe)) if (key !== "kind" && !spec.required.includes(key) && !spec.optional.includes(key)) say(`recipe.${key} is not a field of ${recipe.kind}`);
      const addr = (k) => { if (k in recipe && !isAddress(recipe[k])) say(`recipe.${k} must be a lowercase 0x address`); };
      if (recipe.kind === "log-sum" || recipe.kind === "log-rank") {
        if (recipe.address !== null && !isAddress(recipe.address) && !(Array.isArray(recipe.address) && recipe.address.length >= 1 && recipe.address.length <= 16 && recipe.address.every(isAddress))) say("recipe.address must be a lowercase address, a list of 1 to 16, or null");
        if (typeof recipe.event !== "string" || !/^\s*(event\s+)?[A-Za-z_]\w*\s*\(/.test(recipe.event)) say('recipe.event must be a human-readable event, such as "event Transfer(address indexed from, address indexed to, uint256 value)"');
        if (!isArg(recipe.sumArg)) say("recipe.sumArg must name an event argument");
        if (typeof recipe.abs !== "boolean") say("recipe.abs must be true or false");
        if (recipe.kind === "log-rank") {
          if (!isArg(recipe.groupBy)) say("recipe.groupBy must name an event argument");
          if (!Number.isInteger(recipe.topN) || recipe.topN < 1 || recipe.topN > 32) say("recipe.topN must be an integer from 1 to 32");
        }
        if (recipe.filter !== undefined) {
          if (typeof recipe.filter !== "object" || recipe.filter === null) say("recipe.filter must be an object of argument → value");
          else for (const [k, v] of Object.entries(recipe.filter)) if (!isArg(k) || !(isAddress(v) || isBytes32(v) || isUint(v))) say(`recipe.filter.${k} must be a lowercase address, a bytes32 or a decimal string`);
        }
        const named = (recipe.event ?? "").replace(/^.*\(/, "").replace(/\).*$/, "").split(",").map((p) => p.trim().split(/\s+/).pop());
        for (const k of [recipe.sumArg, recipe.groupBy, ...Object.keys(recipe.filter ?? {})].filter(Boolean)) if (!named.includes(k)) say(`"${k}" is not an argument named in recipe.event (${named.join(", ")})`);
      }
      if (recipe.kind === "call-compare") {
        addr("to");
        if (typeof recipe.function !== "string" || !/^\s*(function\s+)?[A-Za-z_]\w*\s*\(/.test(recipe.function)) say('recipe.function must be a human-readable function, such as "function totalSupply() view returns (uint256)"');
        if (!Array.isArray(recipe.args) || recipe.args.length > 8 || !recipe.args.every((a) => typeof a === "boolean" || isAddress(a) || isBytes32(a) || isUint(a))) say("recipe.args must be a list of up to 8 addresses, decimal strings, bytes32 or booleans");
        if (![">", ">=", "<", "<=", "=="].includes(recipe.op)) say("recipe.op must be one of >, >=, <, <=, ==");
        if (!isUint(recipe.threshold)) say("recipe.threshold must be a decimal string");
      }
      if (recipe.kind === "v4-volume-rank") {
        addr("poolManager"); addr("token");
        if (!Number.isInteger(recipe.initializedSince) || recipe.initializedSince < 0) say("recipe.initializedSince must be a block number");
        if (!Number.isInteger(recipe.topN) || recipe.topN < 1 || recipe.topN > 32) say("recipe.topN must be an integer from 1 to 32");
        if (recipe.yield !== undefined && !["pool", "token"].includes(recipe.yield)) say('recipe.yield must be "pool" or "token"');
        if (recipe.exclude !== undefined && !(Array.isArray(recipe.exclude) && recipe.exclude.length >= 1 && recipe.exclude.length <= 32 && recipe.exclude.every(isAddress))) say("recipe.exclude must be a list of 1 to 32 lowercase addresses");
      }
      if (recipe.kind === "panel" && (typeof recipe.source !== "string" || recipe.source.length === 0 || recipe.source.length > 512)) say("recipe.source must name where the fact was read, in at most 512 characters");
      if (brief?.evidence === "panel" && recipe.kind !== "panel") say("this is a panel-evidence question: the recipe must be { kind: 'panel', source }");
      if (brief && brief.evidence !== "panel" && recipe.kind === "panel") say("this is a chain question: a panel recipe cannot be rerun; use log-sum, log-rank, call-compare or v4-volume-rank");
    }
  }
  return problems;
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  let raw, answer, brief = null;
  try { raw = readFileSync(answerPath); answer = JSON.parse(raw.toString("utf8")); }
  catch (error) { console.error(`${answerPath}: ${error.message}`); process.exit(1); }
  try { brief = JSON.parse(readFileSync(briefPath, "utf8")); } catch { console.error(`(no brief at ${briefPath}; checking the shape only)`); }
  const problems = problemsOf(answer, brief, raw.length);
  if (problems.length === 0) { console.log("ok"); process.exit(0); }
  for (const problem of problems) console.error(`- ${problem}`);
  process.exit(1);
}
