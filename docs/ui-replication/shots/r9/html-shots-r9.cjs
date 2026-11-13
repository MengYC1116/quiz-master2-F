// R9 HTML 原型对照截图：用 Playwright 打开本地交互原型文件，截学习报告
// 默认态（亮/深，本周）+ 本月展开态（亮）+ 空态（亮）+ 错误态（亮），
// 供与 Flutter 截图并排对照。
// 用法：NODE_PATH=/home/hatch/.npm/_npx/f0a362733743bae2/node_modules \
//   node html-shots-r9.cjs [outDir]
// 注意：原型是静态演示数据（9 道题、DEMO_TODAY 2026-11-11），与真实库
// 数字/题目顺序不同——对照只看结构/样式/文案，不逐数比对。
// 空/错态用原型全局量 state + render() 切换（proto-bar 被隐藏后点不到）。
const { chromium } = require('playwright');
const path = require('path');

const OUT = process.argv[2] || __dirname;
const HTML =
  '/home/hatch/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const browser = await chromium.launch();
  const hideChrome = async (page) => {
    await page.evaluate(() => {
      document
        .querySelectorAll('.ahead, .st, .sd, .proto-bar')
        .forEach((el) => (el.style.display = 'none'));
    });
  };
  const shotWin = async (page, name) => {
    await sleep(700);
    await page.evaluate(() => {
      document.querySelector('#toast')?.remove();
    });
    await page.locator('.win').screenshot({ path: path.join(OUT, name) });
  };
  const goReport = async (page) => {
    await page.click('button[data-page="report"]');
    await sleep(500);
  };
  const setState = async (page, s) => {
    // 状态按钮在 proto-bar 里，须在隐藏介绍头之前点。
    await page.click(`button[data-state="${s}"]`);
    await sleep(400);
  };

  for (const scheme of ['light', 'dark']) {
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      colorScheme: scheme,
    });
    const page = await ctx.newPage();
    await page.goto('file://' + HTML);
    await sleep(600);
    await hideChrome(page);
    await goReport(page);
    await shotWin(page, `html-report-${scheme}.png`);
    await ctx.close();
    console.log(`done default ${scheme}`);
  }

  // 本月 + 两组都展开（亮色）。
  {
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      colorScheme: 'light',
    });
    const page = await ctx.newPage();
    await page.goto('file://' + HTML);
    await sleep(600);
    await hideChrome(page);
    await goReport(page);
    await page.click('[data-rpt-range="month"]');
    await sleep(400);
    for (const kind of ['cause', 'kp']) {
      const btn = page.locator(`[data-rpt-more="${kind}"]`);
      if ((await btn.count()) > 0) {
        await btn.click();
        await sleep(400);
      } else {
        console.log(`no more button for ${kind}, skip`);
      }
    }
    await shotWin(page, 'html-report-month-expanded-light.png');
    await ctx.close();
    console.log('done month expanded');
  }

  // 空态 + 错误态（亮色）。
  for (const s of ['empty', 'error']) {
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      colorScheme: 'light',
    });
    const page = await ctx.newPage();
    await page.goto('file://' + HTML);
    await sleep(600);
    await setState(page, s);
    await hideChrome(page);
    await goReport(page);
    await shotWin(page, `html-report-${s}-light.png`);
    await ctx.close();
    console.log(`done ${s}`);
  }

  await browser.close();
  console.log('done');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
