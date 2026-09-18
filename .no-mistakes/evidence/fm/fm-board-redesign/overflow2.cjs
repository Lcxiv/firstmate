const { chromium } = require("/Users/louiscondevaux/.hermes/hermes-agent/node_modules/playwright-core");
(async () => { const b = await chromium.launch({ headless: true, executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" });
 const p = await b.newPage({ viewport: { width: 390, height: 844 } }); await p.goto("file://" + __dirname + "/board-40-steps.html");
 const r = await p.evaluate(() => { const pips = document.querySelector(".bb-item--underway .bb-pips"); const all = [...pips.children]; let n = 40;
   while (document.documentElement.scrollWidth > innerWidth && n > 0) { pips.removeChild(pips.lastChild); n--; }
   const fits = n; all.forEach(c => pips.appendChild(c)); pips.style.flexWrap = "wrap";
   return { mostDotsThatFitAt390: fits, scrollWWithFlexWrap: document.documentElement.scrollWidth }; });
 console.log(JSON.stringify(r)); await b.close(); })();
