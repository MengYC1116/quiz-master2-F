// R6 HTML 原型对照截图：用 Playwright 打开本地交互原型文件，点到错题本
// 三视图（书架 / 目录 / 列表），按亮/深各截一张，供与 Flutter 截图并排对照。
// 用法：PLAYWRIGHT_BROWSERS_PATH=~/workspace/.playwright-browsers \
//   NODE_PATH=<npx 缓存 playwright 的 node_modules> node html-shots-r6.cjs [outDir]
// 注意：原型是静态演示数据（9 道题、DEMO_TODAY 2026-11-11），与真实库
// 数字不同——对照只看结构/样式/文案，不逐数比对。
const { chromium } = require('playwright');
const path = require('path');

const OUT = process.argv[2] || __dirname;
const HTML =
  '/home/hatch/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const browser = await chromium.launch();
  for (const scheme of ['light', 'dark']) {
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      colorScheme: scheme,
    });
    const page = await ctx.newPage();
    await page.goto('file://' + HTML);
    await sleep(600);
    // 只留应用框：隐藏原型介绍头、节标题与状态切换器；toast（复查提醒）
    // 每次渲染后 400ms 弹出，截图前去掉。
    await page.evaluate(() => {
      document
        .querySelectorAll('.ahead, .st, .sd, .proto-bar')
        .forEach((el) => (el.style.display = 'none'));
    });
    const shotWin = async (name) => {
      await sleep(700);
      await page.evaluate(() => {
        document.querySelector('#toast')?.remove();
      });
      await page
        .locator('.win')
        .screenshot({ path: path.join(OUT, name) });
    };
    await page.click('button[data-page="notebook"]');
    await sleep(500);
    await shotWin(`html-shelf-${scheme}.png`);
    // 目录：点数学书封面。
    await page.click('[data-nb-book="数学"]');
    await sleep(500);
    await shotWin(`html-directory-${scheme}.png`);
    // 列表：点「全部题目」。
    await page.click('[data-nb-tocall]');
    await sleep(500);
    await shotWin(`html-list-${scheme}.png`);
    await ctx.close();
    console.log(`done ${scheme}`);
  }
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
