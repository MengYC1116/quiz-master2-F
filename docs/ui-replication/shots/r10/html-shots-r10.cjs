// R10 HTML 原型对照截图：用 Playwright 打开本地交互原型文件，截学科管理
// 默认态（亮/深）+ 学科段展开（亮）+ 封面块展开（亮）+ 知识点树展开一章
// （亮）+ 试卷搜索无匹配（亮）+ 设置默认态（亮/深）+ 外观组展开（亮）
// + 复习组展开（亮），供与 Flutter 截图并排对照。
// 用法：NODE_PATH=/home/hatch/.npm/_npx/f0a362733743bae2/node_modules \
//   node html-shots-r10.cjs [outDir]
// 注意：原型是静态演示数据（9 道题、DEMO_TODAY 2026-11-11），与真实库
// 数字/题名/试卷名不同——对照只看结构/样式/文案，不逐数比对。
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
  const go = async (page, p) => {
    await page.click(`button[data-page="${p}"]`);
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
    await go(page, 'subjects');
    await shotWin(page, `html-subjects-${scheme}.png`);
    await go(page, 'settings');
    await shotWin(page, `html-settings-${scheme}.png`);
    await ctx.close();
    console.log(`done default ${scheme}`);
  }

  // 学科段展开 + 封面块展开（亮色）。
  {
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      colorScheme: 'light',
    });
    const page = await ctx.newPage();
    await page.goto('file://' + HTML);
    await sleep(600);
    await hideChrome(page);
    await go(page, 'subjects');
    await page.click('[data-subj-sec="subjects"]');
    await sleep(400);
    await shotWin(page, 'html-subjects-open-light.png');
    await page.click('[data-cover-fold]');
    await sleep(400);
    await shotWin(page, 'html-subjects-cover-light.png');
    await ctx.close();
    console.log('done subjects open + cover');
  }

  // 知识点树展开第一章（亮色）。
  {
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      colorScheme: 'light',
    });
    const page = await ctx.newPage();
    await page.goto('file://' + HTML);
    await sleep(600);
    await hideChrome(page);
    await go(page, 'subjects');
    await page.click('[data-subj-sec="kp"]');
    await sleep(400);
    const toggle = page.locator('[data-kp-ch-open]').first();
    if ((await toggle.count()) > 0) {
      await toggle.click();
      await sleep(400);
    }
    await shotWin(page, 'html-subjects-kp-light.png');
    await ctx.close();
    console.log('done subjects kp');
  }

  // 试卷搜索无匹配（亮色）：在搜索框输入不存在的卷子。
  {
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      colorScheme: 'light',
    });
    const page = await ctx.newPage();
    await page.goto('file://' + HTML);
    await sleep(600);
    await hideChrome(page);
    await go(page, 'subjects');
    await page.click('[data-subj-sec="papers"]');
    await sleep(400);
    await page.fill('#paper-q', '不存在的卷子');
    await sleep(500);
    await shotWin(page, 'html-subjects-exams-search-light.png');
    await ctx.close();
    console.log('done subjects exams search');
  }

  // 设置外观组 / 复习组展开（亮色）。
  {
    const ctx = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      colorScheme: 'light',
    });
    const page = await ctx.newPage();
    await page.goto('file://' + HTML);
    await sleep(600);
    await hideChrome(page);
    await go(page, 'settings');
    await page.click('[data-set-sec="appearance"]');
    await sleep(400);
    await shotWin(page, 'html-settings-appearance-light.png');
    await page.click('[data-set-sec="review"]');
    await sleep(400);
    await shotWin(page, 'html-settings-review-light.png');
    await ctx.close();
    console.log('done settings appearance + review');
  }

  await browser.close();
})();
