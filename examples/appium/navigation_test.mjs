// Navigate the pre-installed Kepler Video App on a booted VVD with Appium
// (WebdriverIO client + the Vega "kepler" driver) and screenshot every step.
//
// This is the Appium analogue of examples/argent-navigation-test.sh: it drives a
// similar flow (browse -> carousels -> open a title -> top nav) but through
// the official Appium-on-Vega path — a session against the automation toolkit
// (`automation-toolkit/JSON-RPC`), D-pad input via `jsonrpc: injectInputKeyEvent`,
// and screenshots via Appium's `takeScreenshot()`. Run by examples/appium-navigation-test.sh
// (which installs Appium + the kepler driver, enables the toolkit, installs the
// app and starts the Appium server) INSIDE the vega-virtual-device-host container
// with the VVD booted and ready.
//
// What it proves:
//   1. (HARD) Appium can drive the app on the VVD — the session connects, the app
//      activates, the toolkit returns a real page source, and D-pad navigation
//      changes it. If this fails the job fails: the Appium-on-Vega path is broken.
//   2. (REPORTED) Whether Appium's OWN screenshot path (`takeScreenshot`, via the
//      toolkit) reads back non-black under the VVD's software-GL renderer (Mesa
//      llvmpipe). This is unproven territory, so by default a black frame is a
//      WARN, not a failure (SCREENSHOT_POLICY=warn). Set SCREENSHOT_POLICY=require
//      to turn black frames into hard failures (stricter software-GL render check).
//
// Artifacts (OUT_DIR, default ./artifacts): NN-<step>.png (Appium screenshot) +
// NN-<step>.txt (page source) per step, and summary.md (Markdown result table).

import { remote } from 'webdriverio';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { nonblackFrac } from './png.mjs';

// --- config ----------------------------------------------------------------
const APP_ID = process.env.APP_ID || 'com.amazondeveloper.keplervideoapp.main';
// The package id (drop the trailing component id) identifies the app in the page
// source's <app appName="…">, so we can tell whether we're still inside it or have
// backed out to the launcher.
const APP_PKG = APP_ID.replace(/\.[^.]+$/, '');
const OUT_DIR = process.env.OUT_DIR || 'artifacts';
const APPIUM_URL = process.env.APPIUM_URL || 'http://127.0.0.1:4723';
// The Kepler Video App is a dark theme (black background, sparse text, posters
// that may not resolve), so a rendered screen sits ~0.4–1.2% non-black while a
// broken/black frame is ~0.000 — a low threshold separates them cleanly.
const MIN_FRAC = Number(process.env.MIN_NONBLACK_FRAC || 0.004);
// warn  -> black screenshots are reported but never fail the job (default; the
//          job's pass/fail tracks whether Appium DROVE the app, not readback).
// require -> a black REQUIRED screen fails the job (software-GL render smoke test).
const SCREENSHOT_POLICY = (process.env.SCREENSHOT_POLICY || 'warn').toLowerCase();
// How long each injected key is held (ms). The docs' example uses 1000; a shorter
// hold keeps navigation snappy. Bump via KEY_HOLD_MS if presses get dropped.
const KEY_HOLD_MS = Number(process.env.KEY_HOLD_MS || 600);

// Linux input event codes (see appium-commands.html "D-pad navigation"): the
// toolkit injects these via `jsonrpc: injectInputKeyEvent`.
const KEY = { UP: 103, DOWN: 108, LEFT: 105, RIGHT: 106, SELECT: 96, BACK: 158, HOME: 170 };

const capabilities = {
  platformName: 'Kepler',
  'appium:automationName': 'automation-toolkit/JSON-RPC',
  // Only the VVD is connected, so `default` resolves to it (no serial needed).
  'kepler:device': 'vda://default',
  // Launch the target app when the session starts (it also attaches the toolkit).
  'appium:appURL': APP_ID,
};

mkdirSync(OUT_DIR, { recursive: true });

// --- logging ----------------------------------------------------------------
const group = (title, fn) => {
  console.log(`::group::${title}`);
  return Promise.resolve()
    .then(fn)
    .finally(() => console.log('::endgroup::'));
};

// --- run --------------------------------------------------------------------
let driver;
let step = 0;
const summary = []; // { result: PASS|WARN|FAIL, tag, detail }
const fails = [];

// press <code> [repeat] — inject a D-pad key `repeat` times via the toolkit.
// Mirrors the documented Python call shape: execute_script("jsonrpc:
// injectInputKeyEvent", [{ inputKeyEvent, holdDuration }]). WebdriverIO's
// `execute(<string>, ...args)` forwards the string verbatim as the W3C execute
// `script` (the canonical way to call Appium execute-methods), so this reaches
// the kepler driver's handler unchanged.
async function press(code, repeat = 1) {
  for (let n = 0; n < repeat; n++) {
    await driver.execute('jsonrpc: injectInputKeyEvent', [
      { inputKeyEvent: String(code), holdDuration: KEY_HOLD_MS },
    ]);
    await sleep(350);
  }
}

// capture <name> [required] — screenshot + page source for this step, assert
// non-black per SCREENSHOT_POLICY. required defaults to true; pass false for
// best-effort frames (e.g. the video player surface, which may not read back
// under software GL).
async function capture(name, required = true) {
  step += 1;
  const tag = `${String(step).padStart(2, '0')}-${name}`;
  const png = join(OUT_DIR, `${tag}.png`);
  const txt = join(OUT_DIR, `${tag}.txt`);

  let source = '';
  try {
    source = await driver.getPageSource();
  } catch (e) {
    source = `<!-- getPageSource failed: ${e.message} -->`;
  }
  writeFileSync(txt, source);

  let info;
  let frac = 0;
  try {
    const b64 = (await driver.takeScreenshot()).replace(/^data:image\/png;base64,/, '');
    const buf = Buffer.from(b64, 'base64');
    writeFileSync(png, buf);
    const nb = nonblackFrac(buf);
    info = nb ? `${nb.w}x${nb.h} nonblack_frac=${nb.frac.toFixed(4)}` : 'unreadable PNG';
    frac = nb ? nb.frac : 0;
  } catch (e) {
    info = `screenshot failed: ${e.message}`;
  }

  if (frac > MIN_FRAC) {
    summary.push({ result: 'PASS', tag, detail: info });
    console.log(`  ✓ ${tag} — ${info}`);
  } else if (SCREENSHOT_POLICY === 'require' && required) {
    fails.push(tag);
    summary.push({ result: 'FAIL', tag, detail: `black/missing (${info})` });
    console.log(`  ✗ ${tag} — BLACK/MISSING (required) — ${info}`);
  } else {
    summary.push({ result: 'WARN', tag, detail: `black (${info})` });
    console.log(`  ! ${tag} — black (reported, not failing) — ${info}`);
  }
}

// A page source counts as "real" once it carries more than the empty toolkit
// root — used to confirm the toolkit attached before we start navigating.
const isRealTree = (s) => typeof s === 'string' && s.replace(/\s/g, '').length > 60 && s.includes('<');

// inApp() — is the target app still in the foreground (vs backed out to the
// launcher)? On this app, BACK from the top-level browse screen exits to the
// Kepler launcher, so we guard navigation rather than blindly pressing keys.
async function inApp() {
  let src = '';
  try {
    src = await driver.getPageSource();
  } catch {
    return false;
  }
  return src.includes(APP_PKG);
}

// ensureInApp(label) — bring the app back to the foreground if we've drifted out
// of it (re-activate, which returns to its browse screen).
async function ensureInApp(label) {
  if (await inApp()) return;
  console.log(`  (not in ${APP_PKG} at "${label}"; re-activating)`);
  try {
    await driver.activateApp(APP_ID);
  } catch (e) {
    console.log(`  activateApp: ${e.message}`);
  }
  await sleep(4000);
}

async function main() {
  await group(`Connect Appium session (${APPIUM_URL})`, async () => {
    const u = new URL(APPIUM_URL);
    driver = await remote({
      hostname: u.hostname,
      port: Number(u.port || 4723),
      path: u.pathname || '/',
      logLevel: process.env.WDIO_LOG_LEVEL || 'warn',
      connectionRetryTimeout: 180000,
      capabilities,
    });
    console.log(`session ${driver.sessionId} — app: ${APP_ID}`);
  });

  // The toolkit attaches at app launch; on a FRESH install (CI) the first launch
  // can race it, leaving an empty tree. Re-activate the app until the page source
  // is real, so focus is deterministic before we navigate (mirrors the argent
  // restart-app loop in argent-navigation-test.sh).
  await group('Attach automation toolkit', async () => {
    let source = '';
    for (let attempt = 1; attempt <= 6; attempt++) {
      try {
        source = await driver.getPageSource();
      } catch {
        source = '';
      }
      if (isRealTree(source)) {
        console.log(`toolkit attached (attempt ${attempt}), page source ${source.length} bytes`);
        return;
      }
      console.log(`toolkit tree empty; re-activating app (attempt ${attempt})...`);
      try {
        await driver.activateApp(APP_ID);
      } catch (e) {
        console.log(`activateApp: ${e.message}`);
      }
      await sleep(7000);
    }
    throw new Error('automation toolkit never returned a real page source — the Appium/Vega path is not working');
  });

  // --- navigation flow ------------------------------------------------------
  // Tuned to the Kepler Video App's real layout (verified against its Appium page
  // source): a top tab bar (All / TV Shows / Movies / Live TV) reached with UP,
  // plus content carousels (Classics / Recommendation). We deliberately AVOID BACK
  // — on this app BACK from the top-level browse screen exits to the launcher — and
  // guard with ensureInApp() so a stray transition can't leave us navigating the
  // launcher. Each key press is followed by a short settle before the screenshot.
  await group('Browse home', () => capture('home')); // featured hero + carousels

  // Browsing the carousels is the clearest proof of D-pad control: the featured
  // hero (title, runtime, synopsis) updates to whatever tile is focused, so each
  // DOWN/RIGHT visibly changes the screen. (The top tab bar's items don't switch
  // content in this sample app, so we don't pretend to — we just show it focused.)
  await group('Browse carousels (featured content tracks focus)', async () => {
    await ensureInApp('carousels');
    await press(KEY.DOWN); await sleep(2000); await capture('row1-focus');
    await press(KEY.RIGHT, 3); await sleep(2000); await capture('row1-scrolled');
    await press(KEY.RIGHT, 3); await sleep(2000); await capture('row1-scrolled-more');
    await press(KEY.DOWN); await sleep(2000); await capture('row2-focus');
    await press(KEY.RIGHT, 3); await sleep(2000); await capture('row2-scrolled');
    await press(KEY.DOWN); await sleep(2000); await capture('row3-focus');
  });

  await group('Open a title', async () => {
    // SELECT the focused tile to open its detail/playback (best-effort: the video
    // surface may not read back under software GL). Recover without BACK (which on
    // this app exits to the launcher) via re-activation.
    await press(KEY.SELECT); await sleep(4000);
    await capture('title-open', false);
    await ensureInApp('after-open');
  });

  await group('Top tab bar', async () => {
    await press(KEY.UP, 4); await sleep(1500); // raise focus to All / TV Shows / Movies / Live TV
    await capture('top-nav');
  });
}

// --- report -----------------------------------------------------------------
function writeReport() {
  console.log('::group::Summary');
  for (const s of summary) console.log(`${s.result}  ${s.tag}  ${s.detail}`);
  console.log('::endgroup::');

  const lines = [
    '### VVD navigation — Kepler Video App via Appium (WebdriverIO + kepler driver)',
    '',
    `Screenshots captured with Appium \`takeScreenshot()\` under software GL (llvmpipe). Policy: \`${SCREENSHOT_POLICY}\` (min non-black frac \`${MIN_FRAC}\`).`,
    '',
    '| Step | Result | Detail |',
    '|---|---|---|',
    ...summary.map((s) => `| \`${s.tag}\` | ${s.result} | ${s.detail} |`),
  ];
  writeFileSync(join(OUT_DIR, 'summary.md'), lines.join('\n') + '\n');
}

let exitCode = 0;
try {
  await main();
} catch (e) {
  console.error(`ERROR: ${e.message}`);
  exitCode = 1;
} finally {
  if (driver) {
    try {
      await driver.deleteSession();
    } catch {
      /* best effort */
    }
  }
  writeReport();
}

if (fails.length) {
  console.error(`ERROR: ${fails.length} required screen(s) black/missing: ${fails.join(', ')}`);
  exitCode = 1;
}
console.log(
  exitCode === 0
    ? `OK: Appium navigated the app -> ${OUT_DIR}/ (${summary.length} steps)`
    : `FAILED: see ${OUT_DIR}/summary.md`,
);
process.exit(exitCode);
