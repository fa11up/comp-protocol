import { useState, Children, type ReactNode } from "react";
import { type Address } from "viem";
import type { Target } from "./config";
import { Ticker } from "./motion";
import { amount, address, uint, message } from "./math";
export type Request = {
  target: Target;
  fn: string;
  args: readonly unknown[];
  summary: string;
};
export type Actions = {
  ready: boolean;
  busy: string;
  reason: string;
  run: (id: string, request: Request) => Promise<void>;
  account?: Address;
};
export function Action({
  id,
  label,
  actions,
  request,
  disabled = false,
  reason = "",
}: {
  id: string;
  label: string;
  actions: Actions;
  request: () => Request;
  disabled?: boolean;
  reason?: string;
}) {
  const [error, setError] = useState("");
  return (
    <div className="action">
      <button
        type="button"
        disabled={!actions.ready || !!actions.busy || disabled}
        onClick={async () => {
          setError("");
          try {
            await actions.run(id, request());
          } catch (e) {
            setError(message(e));
          }
        }}
      >
        {actions.busy === id ? "Processing…" : label}
      </button>
      <p className="action-note">
        {error ? (
          <span role="alert">{error}</span>
        ) : disabled ? (
          reason
        ) : !actions.ready ? (
          actions.reason
        ) : (
          ""
        )}
      </p>
    </div>
  );
}
export type Field = {
  name: string;
  kind: "amount" | "amount0" | "address" | "uint";
  default?: string;
};
export function ActionForm({
  id,
  label,
  actions,
  target,
  fn,
  fields = [],
  summary,
  disabled = false,
  reason = "",
  mapArgs,
}: {
  id: string;
  label: string;
  actions: Actions;
  target?: Target;
  fn: string;
  fields?: Field[];
  summary: string;
  disabled?: boolean;
  reason?: string;
  mapArgs?: (v: any[]) => readonly unknown[];
}) {
  const [values, setValues] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const [invalidField, setInvalidField] = useState("");
  return (
    <form
      className="action-form"
      onSubmit={async (e) => {
        e.preventDefault();
        setError("");
        setInvalidField("");
        try {
          if (!target) throw Error("Contract has not loaded.");
          const args = fields.map((f) => {
            const t = values[f.name] ?? f.default ?? "";
            try {
              return f.kind === "address"
                ? address(t)
                : f.kind === "amount"
                  ? amount(t)
                  : f.kind === "amount0"
                    ? amount(t, 18, true)
                    : uint(t);
            } catch (error) {
              setInvalidField(f.name);
              (
                e.currentTarget.elements.namedItem(
                  `${id}-${f.name}`,
                ) as HTMLInputElement
              )?.focus();
              throw error;
            }
          });
          await actions.run(id, {
            target,
            fn,
            args: mapArgs ? mapArgs(args) : args,
            summary: `${summary}${args.length ? " Inputs: " + fields.map((f, i) => `${f.name}: ${values[f.name] ?? f.default ?? ""}`).join("; ") : ""}`,
          });
        } catch (e) {
          setError(message(e));
        }
      }}
    >
      {fields.map((f) => (
        <label key={f.name}>
          {f.name}
          <input
            name={`${id}-${f.name}`}
            aria-invalid={invalidField === f.name || undefined}
            aria-describedby={`${id}-feedback`}
            inputMode={f.kind === "address" ? "text" : "decimal"}
            autoComplete="off"
            spellCheck={false}
            required
            value={values[f.name] ?? f.default ?? ""}
            onChange={(e) => setValues({ ...values, [f.name]: e.target.value })}
          />
        </label>
      ))}
      <button
        type="submit"
        disabled={!actions.ready || !!actions.busy || disabled || !target}
      >
        {actions.busy === id ? "Processing…" : label}
      </button>
      <p id={`${id}-feedback`} className="action-note">
        {error ? (
          <span role="alert">{error}</span>
        ) : disabled ? (
          reason
        ) : !actions.ready ? (
          actions.reason
        ) : (
          summary
        )}
      </p>
    </form>
  );
}
export function Pane({
  id,
  index,
  title,
  tag,
  children,
}: {
  id: string;
  index: string;
  title: string;
  tag?: string;
  children: ReactNode;
}) {
  return (
    <section className={`pane pane-${id}`} aria-labelledby={`${id}-heading`}>
      <header className="pane-head">
        <h2 id={`${id}-heading`}>
          <span>{index}</span> {title}
        </h2>
        <span className="tag">
          {tag}
          <span className="scroll-cue" aria-label="Scroll inside pane for more">
            {" "}
            ↕
          </span>
        </span>
      </header>
      <div className="pane-body" tabIndex={0} aria-label={`${title} pane`}>
        {children}
      </div>
    </section>
  );
}
export function Row({
  label,
  children,
}: {
  label: string;
  children: ReactNode;
}) {
  const parts = Children.toArray(children);
  const text = parts.every(
    (x) => typeof x === "string" || typeof x === "number",
  )
    ? parts.join("")
    : undefined;
  return (
    <div className="row">
      <span>{label}</span>
      <strong>{text === undefined ? children : <Ticker text={text} />}</strong>
    </div>
  );
}
export function AddressLink({
  value,
  explorer,
  label,
}: {
  value?: Address;
  explorer: string;
  label: string;
}) {
  const [copied, setCopied] = useState(false);
  return value ? (
    <span className="address">
      <a
        href={`${explorer}/address/${value}`}
        target="_blank"
        rel="noreferrer"
        title={value}
      >
        {label} ↗{" "}
        <span>
          {value.slice(0, 6)}…{value.slice(-4)}
        </span>
      </a>
      <button
        type="button"
        aria-label={`Copy ${label} address`}
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(value);
            setCopied(true);
          } catch {
            setCopied(false);
          }
        }}
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </span>
  ) : (
    <span>—</span>
  );
}
