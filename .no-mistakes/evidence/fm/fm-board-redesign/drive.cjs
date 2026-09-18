const { chromium } = require("/Users/louiscondevaux/.hermes/hermes-agent/node_modules/playwright-core");
const E = __dirname, url = "file://" + E + "/board-live.html";
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" });
  const out = {};
  for (const [name, vp] of [["1280", {width:1280,height:900}], ["390", {width:390,height:844}]]) {
    const ctx = await browser.newContext({ viewport: vp });
    const page = await ctx.newPage();
    const errors = []; page.on("pageerror", e => errors.push(String(e)));
    await page.addInitScript(() => { window.__q = []; window.__sent = 0;
      window.lavish = { queuePrompt: (t, o) => window.__q.push({ text: t, tag: o.tag, data: o.data }), send: () => window.__sent++ }; });
    await page.goto(url);
    const r = out[name] = { errors };
    r.initial = await page.evaluate(() => {
      const items = [...document.querySelectorAll(".bb-item__rank")].map(n => n.closest(".bb-item"));
      const kind = i => (i.className.match(/bb-item--(\w+)/) || [])[1];
      const ell = [...document.querySelectorAll("body *")].filter(n => { const s = getComputedStyle(n); return s.textOverflow === "ellipsis" || s.webkitLineClamp !== "none"; }).length;
      return {
        count: items.length,
        ranks: items.map(i => i.querySelector(".bb-item__rank").textContent + ":" + kind(i)).join(" "),
        allHaveToggle: items.every(i => i.querySelector(".bb-toggle")),
        allCollapsed: items.every(i => { const s = i.querySelector(".bb-steps"); return !s || s.hidden || getComputedStyle(s).display === "none" || s.offsetHeight === 0; }),
        optsVisibleWhileCollapsed: [...document.querySelectorAll(".bb-opt")].every(b => b.offsetHeight > 0),
        summaries: items.slice(0, 4).map(i => (i.querySelector(".bb-item__now") || {}).textContent),
        pips: items.slice(0, 4).map(i => i.querySelectorAll(".bb-pip").length),
        firstCall: items[0].querySelector(".bb-item__title").textContent.slice(0, 60),
        links: [...document.querySelectorAll(".bb-held")].map(a => a.textContent.slice(0, 70) + " -> " + a.getAttribute("href")),
        ellipsisStyled: ell, textEllipsis: document.body.innerText.includes("…"),
        scrollW: document.documentElement.scrollWidth, clientW: document.documentElement.clientWidth,
        landedHidden: document.getElementById("bb-landed").hidden,
      };
    });
    await page.screenshot({ path: `${E}/board-${name}-collapsed.png`, fullPage: true });
    // expand a call, an underway, and the blocked charted item
    const blockedId = await page.evaluate(() => [...document.querySelectorAll(".bb-held")].map(a => a.getAttribute("href")).find(h => h && !/call/.test(h)) );
    for (const sel of [".bb-item--call", ".bb-item--underway"]) await page.locator(sel + " .bb-toggle").first().click();
    const heldItem = page.locator(".bb-item", { has: page.locator(".bb-held", { hasText: "waits on your call" }) }).first();
    await heldItem.locator(".bb-toggle").first().click();
    r.expanded = await page.evaluate(() => [...document.querySelectorAll(".bb-item")].filter(i => { const s = i.querySelector(".bb-steps"); return s && s.offsetHeight > 0; }).map(i => ({ rank: i.querySelector(".bb-item__rank").textContent, aria: i.querySelector(".bb-toggle").getAttribute("aria-expanded"), steps: [...i.querySelectorAll(".bb-step")].map(s => (s.className.match(/bb-step--(\w+)/)||[])[1] + " | " + s.textContent) })));
    r.scrollWExpanded = await page.evaluate(() => document.documentElement.scrollWidth);
    await page.screenshot({ path: `${E}/board-${name}-expanded.png`, fullPage: true });
    await page.locator(".bb-item--call .bb-toggle").first().click();
    r.reclosed = await page.evaluate(() => document.querySelector(".bb-item--call .bb-steps").offsetHeight === 0);
    // one click answers
    await page.locator(".bb-item--call").first().locator(".bb-opt").first().click();
    r.afterOneClick = await page.evaluate(() => ({ queued: window.__q, sent: window.__sent, cardQueued: document.querySelector(".bb-item--call").classList.contains("is-queued"), note: document.querySelector(".bb-item--call .bb-queued").textContent }));
    // queue-all stages, cancel clears, confirm queues, nothing sends
    await page.locator("#bb-bulk-btn").click();
    r.bulkStaged = await page.evaluate(() => ({ stageVisible: !document.getElementById("bb-bulk-stage").hidden, list: [...document.querySelectorAll(".bb-bulk__item")].map(n => n.textContent.slice(0, 80)), queuedCount: window.__q.length }));
    await page.screenshot({ path: `${E}/board-${name}-queue-all-staged.png` });
    await page.locator("#bb-bulk-cancel").click();
    r.bulkCancelled = await page.evaluate(() => ({ stageHidden: document.getElementById("bb-bulk-stage").hidden, queuedCount: window.__q.length }));
    await page.locator("#bb-bulk-btn").click(); await page.locator("#bb-bulk-confirm").click();
    r.bulkConfirmed = await page.evaluate(() => ({ queued: window.__q.map(q => q.data), sent: window.__sent }));
    // long queue: pick the last queued row, dispatch bar stays on screen
    const last = page.locator(".bb-pick").last();
    await last.scrollIntoViewIfNeeded(); await last.check();
    r.longList = await page.evaluate(() => { const picks = document.querySelectorAll(".bb-pick"); const l = picks[picks.length-1].getBoundingClientRect(); const b = document.getElementById("bb-dispatch").getBoundingClientRect(); return { queuedRows: picks.length, lastInView: l.top >= 0 && l.bottom <= innerHeight, barInView: b.top >= 0 && b.bottom <= innerHeight + 1 && b.height > 0, barText: document.getElementById("bb-dispatch-count").textContent, scrollY: Math.round(scrollY) }; });
    await page.screenshot({ path: `${E}/board-${name}-last-queued-pick.png` });
    await page.locator("#bb-dispatch-btn").click();
    r.dispatch = await page.evaluate(() => ({ last: window.__q[window.__q.length-1], sent: window.__sent }));
    await page.locator("#bb-landed-toggle").click();
    r.landed = await page.evaluate(() => ({ hidden: document.getElementById("bb-landed").hidden, prs: [...document.querySelectorAll(".bb-row__pr")].map(a => a.textContent) }));
    await ctx.close();
  }
  await browser.close();
  console.log(JSON.stringify(out, null, 1));
})().catch(e => { console.error(e); process.exit(1); });
