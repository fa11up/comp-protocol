// A clock that runs only while the page is on screen. A background tab or a backgrounded phone app makes no
// chain reads (each one is an RPC call on our account); coming back runs `fn` at once, then every `ms`.
export function everyVisible(fn: () => void, ms: number): () => void {
  let t: ReturnType<typeof setInterval> | null = null;
  const start = () => {
    if (t === null) t = setInterval(fn, ms);
  };
  const stop = () => {
    if (t !== null) clearInterval(t);
    t = null;
  };
  const onVisibility = () => {
    if (document.hidden) stop();
    else if (t === null) {
      fn();
      start();
    }
  };
  if (!document.hidden) start();
  document.addEventListener("visibilitychange", onVisibility);
  return () => {
    stop();
    document.removeEventListener("visibilitychange", onVisibility);
  };
}
