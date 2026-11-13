// R8 HTML 原型对照截图：用 Playwright 打开本地交互原型文件，点到复习页
// 默认态（亮/深）+ 已治愈分组展开（亮）+ 会话四步（看错因/写补救/重做/
// 重做展开答案/自查，亮）+ 总结（亮），供与 Flutter 截图并排对照。
// 用法：NODE_PATH=/home/hatch/.npm/_npx/f0a362733743bae2/node_modules \
//   node html-shots-r8.cjs [outDir]
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
  const goReview = async (page) => {
    await page.click('button[data-page="review"]');
    await sleep(500);
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
    await goReview(page);
    await shotWin(page, `html-review-${scheme}.png`);
    await ctx.close();
    console.log(`done list ${scheme}`);
  }

  // 会话四步 + 已治愈展开 + 总结（亮色）。
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 720 },
    colorScheme: 'light',
  });
  const page = await ctx.newPage();
  await page.goto('file://' + HTML);
  await sleep(600);
  await hideChrome(page);
  await goReview(page);
  // 已治愈分组展开：政治 | 概念不清（p1，已解决、复查未到——原型里
  // check 2026-11-11 = DEMO_TODAY 当天到期，算复查项；为拍已治愈展开，
  // 改点数学 | 概念不清的已治愈行不存在时退回：先试政治组）。
  const curedBtn = page.locator('[data-r2-group="政治|概念不清"]');
  if ((await curedBtn.count()) > 0) {
    await curedBtn.click();
    await sleep(400);
    await shotWin(page, 'html-review-cured-light.png');
    await curedBtn.click();
    await sleep(400);
  } else {
    console.log('no cured group button found, skip cured shot');
  }
  // 会话：开始解决 → 看错因。
  await page.click('[data-r2="start"]');
  await sleep(500);
  await shotWin(page, 'html-review-recall-light.png');
  // 写补救。
  await page.click('[data-r2="to-remedy"]');
  await sleep(400);
  await shotWin(page, 'html-review-remedy-light.png');
  // 重做（答案遮着）。
  await page.click('[data-r2="remedy-done"]');
  await sleep(400);
  await shotWin(page, 'html-review-redo-light.png');
  // 看答案。
  await page.click('[data-r2="show-ans"]');
  await sleep(400);
  await shotWin(page, 'html-review-redo-shown-light.png');
  // 自查。
  await page.click('[data-r2="to-check"]');
  await sleep(400);
  await shotWin(page, 'html-review-check-light.png');
  // 走完剩余全部块，出总结：每块完整走四步（看错因→写补救→重做→自查，
  // 每错因全选“已解决”）再点下一题/看总结。注意两点：① finish-q 之后下
  // 一块回到第①步；② 一题多错因时，写完一个错因的补救会回到第①步走下一
  // 个错因——所以内层循环一直把步骤推到自查步为止。
  for (let round = 0; round < 40; round++) {
    if ((await page.locator('[data-r2="to-list"]').count()) > 0) break;
    for (let step = 0; step < 20; step++) {
      if ((await page.locator('[data-r2="finish-q"]').count()) > 0) break;
      if ((await page.locator('[data-r2="to-list"]').count()) > 0) break;
      if ((await page.locator('[data-r2="to-remedy"]').count()) > 0) {
        await page.click('[data-r2="to-remedy"]');
      } else if ((await page.locator('[data-r2="remedy-done"]').count()) > 0) {
        await page.click('[data-r2="remedy-done"]');
      } else if ((await page.locator('[data-r2="show-ans"]').count()) > 0) {
        await page.click('[data-r2="show-ans"]');
      } else if ((await page.locator('[data-r2="to-check"]').count()) > 0) {
        await page.click('[data-r2="to-check"]');
      } else {
        break;
      }
      await sleep(300);
    }
    const idxs = await page.$$eval('[data-r2-check]', (els) =>
      [...new Set(els.map((e) => e.dataset.r2Check.split('|')[0]))].sort(),
    );
    for (const i of idxs) {
      await page.click(`[data-r2-check="${i}|已解决"]`);
      await sleep(200);
    }
    await page.click('[data-r2="finish-q"]');
    await sleep(400);
    console.log(`round ${round} done`);
  }
  if ((await page.locator('[data-r2="to-list"]').count()) > 0) {
    await shotWin(page, 'html-review-summary-light.png');
    console.log('done summary');
  } else {
    console.log('WARNING: summary not reached');
  }
  await ctx.close();
  await browser.close();
  console.log('done');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
