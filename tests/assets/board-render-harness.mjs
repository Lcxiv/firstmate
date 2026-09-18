// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [action...]
//
// Actions drive the rendered page the way the captain would, after the first
// render and before the report is printed:
//   answer:<card>:<option> click an option on a Captain's Call card (one click
//                          queues that answer for review)
//   type:<card>:<text>     type into a card's freeform box
//   submit:<card>          press that card's Queue typed answer button
//   expand:<list>:<item>   press the steps toggle on item <item> of <list>
//                          (call, underway, or charted)
//   landed-toggle          press the Recently landed Show/Hide toggle
//   bulk-open              press Queue all recommended
//   bulk-cancel            press Cancel in the staged list
//   bulk-confirm           press Queue these answers
//
// Prints one JSON document: { stats, charted, underway, empty, more, maps,
//   error, chartedRegion:{rows,sub}, call:{cards,sub}, bulk:{...},
//   queued:[...], sent:<count> }. Every call, underway, and charted item
//   reports its todos: { collapsed, toggle, summary, pips, steps:[...] }.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const actions = process.argv.slice(3);

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    const classes = () => this.className.split(/\s+/).filter(Boolean);
    this.classList = {
      add: (c) => { if (!classes().includes(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = classes().filter((x) => x !== c).join(" "); },
      toggle: (c, on) => { (on ?? !classes().includes(c)) ? this.classList.add(c) : this.classList.remove(c); },
      contains: (c) => classes().includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  insertBefore(n, ref) {
    const i = ref ? this.children.indexOf(ref) : -1;
    n.parentNode = this;
    if (i < 0) this.children.push(n); else this.children.splice(i, 0, n);
    return n;
  }
  setAttribute(k, v) { this.attributes[k] = v; }
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  // Real clicks and submits are how the board's controls are reached, so the
  // shim dispatches them instead of reaching into the page's internals.
  dispatch(type, event = {}) {
    if (this.disabled) return;
    for (const fn of this.listeners[type] || []) fn({ preventDefault() {}, ...event });
  }
  click() { this.dispatch("click"); }
  // Supports the two selector shapes the board and this harness use: a single
  // class (optionally `:checked`) and a bare tag name.
  querySelectorAll(sel) {
    const byClass = sel.startsWith(".");
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const hit = (c) => (byClass ? c.className.split(/\s+/).includes(want) : c.tagName === want);
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (hit(c) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

const byId = new Map();
// Seed every id the shipped markup declares, carrying its initial `hidden`
// state, so a section the renderer never un-hides reports as hidden here just
// as it renders in a browser.
for (const tag of html.match(/<[a-zA-Z][^>]*\bid="[^"]+"[^>]*>/g) || []) {
  const id = tag.match(/\bid="([^"]+)"/)[1];
  if (byId.has(id)) continue;
  const node = new Node((tag.match(/^<([a-zA-Z0-9]+)/) || [, "div"])[1]);
  node.hidden = /\shidden[\s/>]/.test(tag);
  // The renderer reaches a couple of wrappers through parentNode, so every
  // element gets one, exactly as the lazily minted nodes below do.
  new Node("div").appendChild(node);
  byId.set(id, node);
}

const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for that the markup did not declare:
  // the shim tracks whatever ids the shipped template actually uses instead of
  // pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
const queued = [];
let sent = 0;
globalThis.window = {
  lavish: {
    queuePrompt: (prompt, opts = {}) => queued.push({
      prompt,
      tag: opts.tag,
      text: opts.text,
      question: opts.data ? opts.data.question : undefined,
      answer: opts.data ? opts.data.answer : undefined,
      close: opts.data ? opts.data.close : undefined,
    }),
    sendQueuedPrompts: () => { sent += 1; },
  },
};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const deck = byId.get("bb-call") || new Node("div");
const callCards = () => deck.children.filter((c) => c.className.split(/\s+/).includes("bb-decision"));
const listItems = (id) => (byId.get(id) || new Node("div")).children
  .filter((c) => c.className.split(/\s+/).includes("bb-item"));
const lists = { call: "bb-call", underway: "bb-underway", charted: "bb-charted" };

for (const action of actions) {
  const [verb, ...args] = action.split(":");
  const card = callCards()[Number(args[0])];
  if (verb === "answer") card.querySelectorAll(".bb-opt")[Number(args[1])].click();
  else if (verb === "type") card.querySelector(".bb-freeform").value = args.slice(1).join(":");
  else if (verb === "submit") card.querySelector("form").dispatch("submit");
  else if (verb === "expand") listItems(lists[args[0]])[Number(args[1])].querySelector(".bb-toggle").click();
  else if (verb === "landed-toggle") byId.get("bb-landed-toggle").click();
  else if (verb === "bulk-open") byId.get("bb-bulk-btn").click();
  else if (verb === "bulk-cancel") byId.get("bb-bulk-cancel").click();
  else if (verb === "bulk-confirm") byId.get("bb-bulk-confirm").click();
  else throw new Error("unknown harness action: " + action);
}

const badgesOf = (node) =>
  node.querySelectorAll(".fm-badge")
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));
const text = (node, cls) => node.querySelector(cls)?.textContent ?? "";

// What one todo item shows: collapsed by default behind its toggle, a summary
// and one pip per step on the head row, and the ordered steps themselves.
const todosOf = (item) => {
  const list = item.querySelector(".bb-steps");
  const toggle = item.querySelector(".bb-toggle");
  return {
    collapsed: list ? list.hidden === true : true,
    toggle: toggle ? toggle.textContent : "",
    expanded: toggle ? toggle.getAttribute("aria-expanded") === "true" : false,
    summary: text(item, ".bb-item__now"),
    pips: item.querySelectorAll(".bb-pip").map((p) => p.className.replace(/.*bb-pip--/, "").trim()),
    steps: (list ? list.children : []).map((li) => ({
      text: text(li, ".bb-step__text"),
      state: li.className.replace(/.*bb-step--/, "").trim(),
      you: !!li.querySelector(".bb-step__who"),
    })),
  };
};
const heldOf = (item) => item.querySelectorAll(".bb-held").map((h) => ({ text: h.textContent, href: h.href ?? "" }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const ch = byId.get("bb-charted") || new Node("div");
const charted = listItems("bb-charted").map((item) => ({
  id: item.getAttribute("id"),
  rank: text(item, ".bb-item__rank"),
  title: text(item, ".bb-item__title"),
  badges: badgesOf(item),
  pickable: !!item.querySelector(".bb-pick"),
  held: heldOf(item),
  todos: todosOf(item),
}));
const underway = listItems("bb-underway").map((item) => ({
  id: item.getAttribute("id"),
  rank: text(item, ".bb-item__rank"),
  title: text(item, ".bb-item__title"),
  badges: badgesOf(item),
  held: heldOf(item),
  todos: todosOf(item),
}));
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const emptyOf = (id) => (byId.get(id) || new Node("div")).children
  .filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const empty = emptyOf("bb-charted");
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);
// The queue is never cut short or moved into a nested region: every row the
// payload carries is an item on the page, which itself scrolls.
const chartedRegion = {
  rows: charted.length,
  sub: (byId.get("bb-charted-sub") || new Node("span")).textContent,
  dispatchShown: (byId.get("bb-dispatch") || new Node("div")).hidden === false,
};

const landedHost = byId.get("bb-landed") || new Node("div");
const landed = {
  open: landedHost.hidden === false,
  toggle: (byId.get("bb-landed-toggle-text") || new Node("span")).textContent,
  sub: (byId.get("bb-landed-sub") || new Node("span")).textContent,
  rows: landedHost.children.map((r) => ({
    what: text(r, ".bb-landed-row__what"),
    pr: text(r, ".bb-row__pr"),
  })),
};

const call = {
  sub: (byId.get("bb-call-sub") || new Node("span")).textContent,
  empty: emptyOf("bb-call"),
  cards: callCards().map((card) => {
    const form = card.querySelector("form");
    return {
      id: card.getAttribute("id"),
      key: form?.getAttribute("data-lavish-question") ?? "",
      rank: text(card, ".bb-item__rank"),
      title: text(card, ".bb-item__title"),
      options: card.querySelectorAll(".bb-opt").map((o) => ({
        // the label's own text, without the rec marker nested inside it
        label: o.querySelector(".bb-opt__label")?._text ?? "",
        value: o.value,
        rec: !!o.querySelector(".bb-opt__rec"),
        picked: o.classList.contains("is-picked"),
      })),
      noOptionsNote: text(card, ".bb-opt-none"),
      freeform: !!card.querySelector(".bb-freeform"),
      queued: card.classList.contains("is-queued"),
      queuedText: text(card, ".bb-queued"),
      limit: text(card, ".bb-limit"),
      limitShown: !!card.querySelector(".bb-limit")?.classList.contains("is-visible"),
      held: heldOf(card),
      todos: todosOf(card),
    };
  }),
};

const bulkHost = byId.get("bb-bulk");
const bulkStage = byId.get("bb-bulk-stage");
const bulkNote = byId.get("bb-bulk-note");
const bulk = {
  shown: bulkHost ? bulkHost.hidden === false : false,
  count: (byId.get("bb-bulk-count") || new Node("span")).textContent,
  staging: bulkStage ? bulkStage.hidden === false : false,
  staged: (byId.get("bb-bulk-list") || new Node("ul")).children.map((li) => li.textContent),
  lead: (byId.get("bb-bulk-lead") || new Node("span")).textContent,
  note: bulkNote && bulkNote.hidden === false ? bulkNote.textContent : "",
  canQueueAll: !(byId.get("bb-bulk-btn") || new Node("button")).disabled,
};

const mapsHost = byId.get("bb-maps") || new Node("div");
const mapsSection = byId.get("bb-maps-section");
const maps = {
  // The band is hidden until the renderer un-hides it, so a home with no maps
  // is distinguishable from one whose cards failed to render.
  shown: mapsSection ? mapsSection.hidden === false : false,
  sub: (byId.get("bb-maps-sub") || new Node("span")).textContent,
  cards: mapsHost.children
    .filter((c) => c.className.split(/\s+/).includes("bb-map"))
    .map((card) => ({
      title: card.children.find((c) => c.className.includes("bb-map__title"))?.textContent ?? "",
      dest: card.children.find((c) => c.className.includes("bb-map__dest"))?.textContent ?? "",
      badges: card.children
        .filter((c) => c.className.includes("bb-map__badges"))
        .flatMap((b) => badgesOf(b)),
      notes: card.children
        .filter((c) => c.className.includes("bb-map__note"))
        .map((c) => c.textContent),
    })),
};

process.stdout.write(JSON.stringify({
  stats, charted, underway, landed, empty, more, maps, error: errorText,
  chartedRegion, call, bulk, queued, sent,
}) + "\n");
