import {
  useEffect,
  useId,
  useRef,
  useState,
  Children,
  type ReactNode,
} from "react";
import { type Address } from "viem";
import type { Target } from "./config";
import { Ticker } from "./motion";
import { amount, address, uint, message } from "./math";
import type { Failure } from "./explain";
export type Request = {
  target: Target;
  fn: string;
  args: readonly unknown[];
  summary: string;
  /** Figures only this call site knows, e.g. an inspected borrower's ratio. */
  explain?: (f: Failure) => string | undefined;
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
  explain,
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
  explain?: Request["explain"];
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
            explain,
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
  desk = false,
  children,
}: {
  id: string;
  index: string;
  title: string;
  tag?: string;
  /** A desk pane is a tab panel laid out to fit without scrolling. */
  desk?: boolean;
  children: ReactNode;
}) {
  return (
    <section
      className={`pane pane-${id}${desk ? " desk-pane" : ""}`}
      aria-labelledby={`${id}-heading`}
      id={desk ? `${id}-panel` : undefined}
      role={desk ? "tabpanel" : undefined}
    >
      <header className="pane-head">
        <h2 id={`${id}-heading`}>
          <span>{index}</span> {title}
        </h2>
        <span className="tag">
          {tag}
          {!desk && (
            <span
              className="scroll-cue"
              aria-label="Scroll inside pane for more"
            >
              {" "}
              ↕
            </span>
          )}
        </span>
      </header>
      <div
        className={desk ? "pane-body desk-body" : "pane-body"}
        tabIndex={desk ? undefined : 0}
        aria-label={desk ? undefined : `${title} pane`}
      >
        {children}
      </div>
    </section>
  );
}
/** One of several alternative actions; only the chosen one is drawn, so the column never grows. */
export function Choice({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: readonly (readonly [string, string])[];
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <div className="choice" role="group" aria-label={label}>
      {options.map(([v, text]) => (
        <button
          key={v}
          type="button"
          aria-pressed={value === v}
          onClick={() => onChange(v)}
        >
          {text}
        </button>
      ))}
    </div>
  );
}
export function Col({
  label,
  children,
}: {
  label: string;
  children: ReactNode;
}) {
  return (
    <div className="desk-col">
      <div className="section-label">{label}</div>
      {children}
    </div>
  );
}
export function Row({
  label,
  info,
  children,
}: {
  label: string;
  /** Explanation shown on hover or focus, so the pane itself lists only figures. */
  info?: string;
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
      <span>
        {label}
        {info && <Info label={label} text={info} />}
      </span>
      <strong>{text === undefined ? children : <Ticker text={text} />}</strong>
    </div>
  );
}
/**
 * An "i" that opens a small window on hover, focus or tap. The window is fixed to the viewport
 * rather than the pane, so a scrolling pane can never clip it.
 */
export function Info({ label, text }: { label: string; text: string }) {
  const id = useId();
  const button = useRef<HTMLButtonElement>(null);
  const [at, setAt] = useState<{ x: number; y: number; above: boolean }>();
  const show = () => {
    const r = button.current?.getBoundingClientRect();
    if (!r) return;
    const above = r.top > innerHeight / 2;
    setAt({
      x: Math.min(Math.max(r.left + r.width / 2, 150), innerWidth - 150),
      y: above ? r.top - 6 : r.bottom + 6,
      above,
    });
  };
  const hide = () => setAt(undefined);
  useEffect(() => {
    if (!at) return;
    // A fixed window would drift from its icon once the pane scrolls, so close it instead.
    addEventListener("scroll", hide, true);
    addEventListener("resize", hide);
    return () => {
      removeEventListener("scroll", hide, true);
      removeEventListener("resize", hide);
    };
  }, [at]);
  return (
    <span className="info">
      <button
        ref={button}
        type="button"
        className="info-button"
        aria-label={`About ${label}`}
        aria-describedby={id}
        aria-expanded={!!at}
        onMouseEnter={show}
        onMouseLeave={hide}
        onFocus={show}
        onBlur={hide}
        onClick={() => (at ? hide() : show())}
        onKeyDown={(e) => {
          if (e.key === "Escape") hide();
        }}
      >
        <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
          <path
            d="M8 1.25a6.75 6.75 0 1 0 0 13.5a6.75 6.75 0 1 0 0-13.5z"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.25"
          />
          <path
            d="M8 7v4.25M8 4.75v.01"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
          />
        </svg>
      </button>
      <span
        role="tooltip"
        id={id}
        className="tooltip"
        hidden={!at}
        style={
          at
            ? {
                left: at.x,
                top: at.y,
                transform: `translate(-50%, ${at.above ? "-100%" : "0"})`,
              }
            : undefined
        }
      >
        {text}
      </span>
    </span>
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
