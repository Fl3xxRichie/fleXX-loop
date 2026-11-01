// Generic CDP geometry probe for UI acceptance checks (flexx-review).
//
// Usage:
//   node cdp-geometry-probe.mjs --base http://127.0.0.1:3014 \
//     --paths /shop,/product/slug --widths 360,390,414 --selector article \
//     [--cookie flexxship_admin=JWT] [--port 9333]
//
// Reports, per path and width: horizontal overflow, element count, intrinsic
// element heights, tap targets under 44px inside the matched elements, and the
// aria-labels present (the reliable way to read rendered copy).
//
// No dependencies: Node 22+ global WebSocket drives Chrome directly. Chrome
// path comes from CHROME, defaulting to the Windows install.
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const argv = process.argv.slice(2);
const args = {};
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i].startsWith("--")) args[argv[i].slice(2)] = argv[i + 1];
}

const BASE = (args.base ?? "http://127.0.0.1:3000").replace(/\/$/, "");
const PATHS = (args.paths ?? "/").split(",").filter(Boolean);
const WIDTHS = (args.widths ?? "360,390,414").split(",").map(Number).filter(Boolean);
const SELECTOR = args.selector ?? "article";
const COOKIE = args.cookie ?? "";
const PORT = Number(args.port ?? 9333);
const CHROME = process.env.CHROME ?? "C:/Program Files/Google/Chrome/Application/chrome.exe";
const PROFILE = `C:/Users/${process.env.USERNAME ?? "USER"}/AppData/Local/Temp/cdp-geometry-${Date.now()}`;

const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${PROFILE}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-gpu",
    "--hide-scrollbars",
    "about:blank",
  ],
  { stdio: "ignore" },
);

async function waitJson(url, tries = 80) {
  for (let i = 0; i < tries; i += 1) {
    try {
      const res = await fetch(url);
      if (res.ok) return await res.json();
    } catch {}
    await sleep(250);
  }
  throw new Error(`no response from ${url}`);
}

const list = await waitJson(`http://127.0.0.1:${PORT}/json/list`);
const target = list.find((t) => t.type === "page");
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.addEventListener("open", resolve, { once: true });
  ws.addEventListener("error", reject, { once: true });
});

let nextId = 1;
const pending = new Map();
ws.addEventListener("message", (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) {
    const entry = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.error) entry.reject(new Error(JSON.stringify(msg.error)));
    else entry.resolve(msg.result);
  }
});
function send(method, params = {}) {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

await send("Page.enable");
await send("Runtime.enable");
await send("Network.enable");
if (COOKIE.includes("=")) {
  const [name, ...rest] = COOKIE.split("=");
  const host = new URL(BASE).hostname;
  await send("Network.setCookie", { name, value: rest.join("="), domain: host, path: "/" });
}

async function evaluate(expression) {
  const result = await send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
    userGesture: true,
  });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}

async function nav(url) {
  await send("Page.navigate", { url });
  for (let i = 0; i < 100; i += 1) {
    const ready = await evaluate("document.readyState").catch(() => null);
    if (ready === "complete") break;
    await sleep(100);
  }
  await sleep(1400);
}

const probe = `(() => {
  const sel = ${JSON.stringify(SELECTOR)};
  const nodes = [...document.querySelectorAll(sel)];
  const unique = (vals) => [...new Set(vals)];
  const roots = nodes.length > 0 ? nodes : [document.body];
  const taps = roots.flatMap((root) => [...root.querySelectorAll("button, a, input, textarea, select")])
    .map((el) => {
      const r = el.getBoundingClientRect();
      return {
        label: (el.getAttribute("aria-label") || el.innerText || el.tagName).trim().slice(0, 48),
        w: +r.width.toFixed(1),
        h: +r.height.toFixed(1),
      };
    })
    .filter((t) => t.w > 0 && t.h > 0 && Math.min(t.w, t.h) < 44);
  return {
    path: location.pathname + location.search,
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth: window.innerWidth,
    overflow: document.documentElement.scrollWidth > window.innerWidth,
    selector: sel,
    count: nodes.length,
    heights: unique(nodes.map((n) => +n.getBoundingClientRect().height.toFixed(2))),
    smallTapTargets: taps.slice(0, 20),
    ariaLabels: unique([...document.querySelectorAll("[aria-label]")].map((e) => e.getAttribute("aria-label"))).slice(0, 25),
  };
})()`;

const out = {};
for (const width of WIDTHS) {
  await send("Emulation.setDeviceMetricsOverride", {
    width,
    height: 900,
    deviceScaleFactor: 1,
    mobile: width < 768,
  });
  for (const path of PATHS) {
    await nav(`${BASE}${path}`);
    out[`${path}@${width}`] = await evaluate(probe);
  }
}

console.log(JSON.stringify(out, null, 2));
ws.close();
chrome.kill();
process.exit(0);
