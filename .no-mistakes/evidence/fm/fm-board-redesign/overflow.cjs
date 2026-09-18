const { chromium } = require("/Users/louiscondevaux/.hermes/hermes-agent/node_modules/playwright-core");
(async () => { const b = await chromium.launch({ headless: true, executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" });
 for (const w of [390, 1280]) { const p = await b.newPage({ viewport: { width: w, height: 844 } }); await p.goto("file://" + __dirname + "/board-40-steps.html");
 console.log(w, JSON.stringify(await p.evaluate(() => ({ scrollW: document.documentElement.scrollWidth, wide: [...document.querySelectorAll("body *")].filter(n => n.getBoundingClientRect().right > innerWidth + 1).map(n => n.className + ":" + Math.round(n.getBoundingClientRect().right)).slice(0, 8) }))));
 if (w === 390) await p.screenshot({ path: __dirname + "/board-390-40-steps-overflow.png" }); }
 await b.close(); })();
