// R7 HTML 原型对照截图：用 Playwright 打开本地交互原型文件，点到题目详情页
// 默认态（亮/深）+ 答案展开（亮）+ 信息展开（深）+ 复习展开（亮）+ 编辑态（亮），
// 供与 Flutter 截图并排对照。
// 用法：PLAYWRIGHT_BROWSERS_PATH=~/workspace/.playwright-browsers \
//   NODE_PATH=<npx 缓存 playwright 的 node_modules> node html-shots-r7.cjs [outDir]
// 注意：原型是静态演示数据（9 道题、DEMO_TODAY 2026-11-11），与真实库
// 数字/题目顺序不同——对照只看结构/样式/文案，不逐数比对。
const { chromium } = require('playwright');
const path = require('path');

const OUT = process.argv[2] || __dirname;
const HTML =
  '/home/hatch/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const browser = await chromium.launch();
  const goDetail = async (page) => {
    await page.click('button[data-page="notebook"]');
    await sleep(400);
    await page.click('[data-nb-book="数学"]');
    await sleep(400);
    await page.click('[data-nb-tocall]');
    await sleep(400);
    await page.click('[data-nb-row="m3"]');
    await sleep(500);
  };
  const shotWin = async (page, name) => {
    await sleep(700);
    await page.evaluate(() => {
      document.querySelector('#toast')?.remove();
    });
    await page.locator('.win').screenshot({ path: path.join(OUT, name) });
  };
  const hideChrome = async (page) => {
    await page.evaluate(() => {
      document
        .querySelectorAll('.ahead, .st, .sd, .proto-bar')
        .forEach((el) => (el.style.display = 'none'));
    });
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
    await goDetail(page);
    await shotWin(page, `html-detail-${scheme}.png`);
    await ctx.close();
    console.log(`done default ${scheme}`);
  }

  // 展开态与编辑态：亮色答案/复习/编辑，深色信息。
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 720 },
    colorScheme: 'light',
  });
  const page = await ctx.newPage();
  await page.goto('file://' + HTML);
  await sleep(600);
  await hideChrome(page);
  await goDetail(page);
  // 答案展开：先展开折叠，再点「看答案」。
  await page.click('[data-detail-fold="ans"]');
  await sleep(400);
  await page.click('[data-detail-showans="1"]');
  await sleep(400);
  await shotWin(page, 'html-detail-answer-light.png');
  // 复习展开：回到详情（重新进），只展开复习折叠。
  await page.click('[data-detail-back="1"]');
  await sleep(400);
  await page.click('[data-nb-row="m3"]');
  await sleep(500);
  await page.click('[data-detail-fold="rev"]');
  await sleep(400);
  await shotWin(page, 'html-detail-review-light.png');
  // 编辑态：重新进详情，点「编辑」。
  await page.click('[data-detail-back="1"]');
  await sleep(400);
  await page.click('[data-nb-row="m3"]');
  await sleep(500);
  await page.click('[data-detail-edit="1"]');
  await sleep(500);
  await shotWin(page, 'html-detail-edit-light.png');
  await ctx.close();
  console.log('done light states');

  const ctx2 = await browser.newContext({
    viewport: { width: 1280, height: 720 },
    colorScheme: 'dark',
  });
  const page2 = await ctx2.newPage();
  await page2.goto('file://' + HTML);
  await sleep(600);
  await hideChrome(page2);
  await goDetail(page2);
  await page2.click('[data-detail-fold="info"]');
  await sleep(400);
  await shotWin(page2, 'html-detail-info-dark.png');
  await ctx2.close();
  console.log('done dark info');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
