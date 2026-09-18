const { chromium } = require("/Users/louiscondevaux/.hermes/hermes-agent/node_modules/playwright-core");
(async () => { const b = await chromium.launch({ headless: true, executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" });
 const p = await b.newPage({ viewport: { width: 390, height: 844 } }); await p.goto("file://" + __dirname + "/board-40-steps.html");
 const it = p.locator(".bb-item--underway").first(); await it.locator(".bb-toggle").click();
 console.log(JSON.stringify(await it.evaluate(i => { const s = [...i.querySelectorAll(".bb-step")]; const ol = i.querySelector(".bb-steps"); return { steps: s.length, allVisible: s.every(x => x.offsetHeight > 0), last: s[39].textContent, nestedScroll: ol.scrollHeight > ol.clientHeight + 1, summary: i.querySelector(".bb-item__now").textContent, pageScrollW: document.documentElement.scrollWidth }; })));
 await it.screenshot({ path: __dirname + "/board-390-40-steps.png" }); await b.close(); })();
