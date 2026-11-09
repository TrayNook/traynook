import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../src/scripts/clipboard.js', import.meta.url), 'utf8');
const copies = ['en', 'ru'].map(locale => JSON.parse(readFileSync(new URL(`../src/i18n/${locale}.json`, import.meta.url), 'utf8')).install);
const commands = 'brew tap traynook/tap\nbrew install traynook';

function page({ copy = copies[0], commandsByWidget = [{ id: 'demo-install-command', text: commands }], clipboardAvailable = true, writeText = async () => {} } = {}) {
  const writes = [];
  const lookups = [];
  const timers = new Map();
  let nextTimer = 0;
  let now = 0;
  let cleared = false;
  const ranges = [];
  const selection = {
    removeAllRanges() { cleared = true; ranges.length = 0; },
    addRange(value) { ranges.push(value); },
  };
  const widgets = commandsByWidget.map(({ id, text, copy: widgetCopy = copy }) => {
    let onClick;
    let focused = false;
    const code = { textContent: text, parentElement: { focus() { focused = true; } } };
    const status = { textContent: 'Previous result' };
    const button = {
      hidden: true,
      disabled: false,
      dataset: { copied: widgetCopy.copied, copyFailed: widgetCopy.failed },
      getAttribute(name) { assert.equal(name, 'aria-controls'); return id; },
      closest(selector) {
        assert.equal(selector, '[data-install-command]');
        return { querySelector(selector) { assert.equal(selector, '[data-copy-feedback]'); return status; } };
      },
      addEventListener(type, callback) {
        assert.equal(type, 'click');
        onClick = callback;
      },
    };
    return { id, button, code, status, get focused() { return focused; }, get bound() { return Boolean(onClick); }, click: () => onClick() };
  });
  runInNewContext(script, {
    document: {
      querySelectorAll(selector) {
        assert.equal(selector, '[data-copy-command]');
        return widgets.map(widget => widget.button);
      },
      getElementById(id) { lookups.push(id); return widgets.find(widget => widget.id === id)?.code; },
      createRange: () => ({ selectNodeContents(node) { this.node = node; } }),
    },
    navigator: clipboardAvailable ? { clipboard: { writeText(text) { writes.push(text); return writeText(text); } } } : {},
    window: { getSelection: () => selection },
    setTimeout(callback, delay) {
      const id = ++nextTimer;
      timers.set(id, { callback, delay, at: now + delay });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
  }, { filename: 'clipboard.js' });
  return {
    widgets, writes, lookups, ranges, timers,
    advance(milliseconds) {
      now += milliseconds;
      for (const [id, timer] of [...timers]) {
        if (timer.at <= now) {
          timers.delete(id);
          timer.callback();
        }
      }
    },
    get cleared() { return cleared; },
  };
}

function assertManualCopy(view, copy) {
  const widget = view.widgets[0];
  assert.equal(widget.focused, true);
  assert.equal(view.cleared, true);
  assert.equal(view.ranges.length, 1);
  assert.equal(view.ranges[0].node, widget.code);
  assert.equal(view.ranges[0].node.textContent, commands);
  assert.equal(widget.status.textContent, copy.failed);
  assert.equal(widget.button.disabled, false);
  assert.equal(widget.button.dataset.copyState, undefined);
  assert.equal(view.timers.size, 0);
}

test('copies the exact two-line command and reports success in each page language', async () => {
  for (const copy of copies) {
    const view = page({ copy });
    const widget = view.widgets[0];
    assert.equal(widget.button.hidden, false);
    assert.equal(widget.bound, true);
    await widget.click();
    assert.deepEqual(view.writes, [commands]);
    assert.equal(widget.status.textContent, copy.copied);
    assert.equal(widget.button.dataset.copyState, 'copied');
    assert.equal(widget.button.disabled, false);
    assert.equal(widget.focused, false);
    assert.equal(view.ranges.length, 0);
  }
});

test('clipboard rejection focuses and selects the command with localized manual-copy feedback', async () => {
  for (const copy of copies) {
    const view = page({ copy, writeText: async () => { throw new Error('Permission denied'); } });
    await view.widgets[0].click();
    assert.deepEqual(view.writes, [commands]);
    assertManualCopy(view, copy);
  }
});

test('an unavailable Clipboard API still selects the complete command for manual copying', async () => {
  const view = page({ clipboardAvailable: false });
  await view.widgets[0].click();
  assert.equal(view.writes.length, 0);
  assertManualCopy(view, copies[0]);
});

test('copy button stays disabled while a write is pending and clears stale feedback', async () => {
  let complete;
  const pending = new Promise(resolve => { complete = resolve; });
  const view = page({ writeText: () => pending });
  const widget = view.widgets[0];
  const clicked = widget.click();
  assert.equal(widget.button.disabled, true);
  assert.equal(widget.status.textContent, '');
  complete();
  await clicked;
  assert.equal(widget.button.disabled, false);
  assert.equal(widget.status.textContent, copies[0].copied);
});

test('multiple controls copy their own command and update only their own button and feedback', async () => {
  const complete = [];
  const secondCommand = 'a distinct second command';
  const view = page({
    commandsByWidget: [
      { id: 'demo-install-command', text: commands, copy: copies[0] },
      { id: 'faq-install-command', text: secondCommand, copy: copies[1] },
    ],
    writeText: () => new Promise(resolve => { complete.push(resolve); }),
  });
  const [demo, faq] = view.widgets;
  assert.deepEqual(view.lookups, ['demo-install-command', 'faq-install-command']);
  assert.equal(demo.button.hidden, false);
  assert.equal(faq.button.hidden, false);
  const demoClick = demo.click();
  assert.equal(demo.button.disabled, true);
  assert.equal(faq.button.disabled, false);
  assert.equal(demo.status.textContent, '');
  assert.equal(faq.status.textContent, 'Previous result');
  complete[0]();
  await demoClick;
  assert.equal(demo.button.disabled, false);
  assert.equal(demo.status.textContent, copies[0].copied);
  const faqClick = faq.click();
  assert.equal(faq.button.disabled, true);
  assert.equal(demo.button.disabled, false);
  assert.equal(demo.status.textContent, copies[0].copied);
  complete[1]();
  await faqClick;
  assert.deepEqual(view.writes, [commands, secondCommand]);
  assert.equal(faq.button.disabled, false);
  assert.equal(faq.status.textContent, copies[1].copied);
  assert.equal(demo.status.textContent, copies[0].copied);
});

test('pages without copy controls do not bind events or use clipboard resources', () => {
  const view = page({ commandsByWidget: [] });
  assert.equal(view.widgets.length, 0);
  assert.equal(view.writes.length, 0);
  assert.equal(view.ranges.length, 0);
  assert.deepEqual(view.lookups, []);
  assert.equal(view.timers.size, 0);
});

test('success feedback lasts 2500 milliseconds and then resets without disabling the control', async () => {
  const view = page();
  const widget = view.widgets[0];
  await widget.click();
  assert.equal(view.timers.size, 1);
  assert.equal([...view.timers.values()][0].delay, 2500);
  view.advance(2499);
  assert.equal(widget.button.dataset.copyState, 'copied');
  assert.equal(widget.status.textContent, copies[0].copied);
  view.advance(1);
  assert.equal(widget.button.dataset.copyState, undefined);
  assert.equal(widget.status.textContent, '');
  assert.equal(widget.button.disabled, false);
  assert.equal(view.timers.size, 0);
});

test('a repeated copy cancels the previous reset and gives the newer success its full duration', async () => {
  const view = page();
  const widget = view.widgets[0];
  await widget.click();
  const previousTimer = [...view.timers.keys()][0];
  view.advance(1000);
  const clickedAgain = widget.click();
  assert.equal(view.timers.has(previousTimer), false);
  assert.equal(widget.button.dataset.copyState, undefined);
  assert.equal(widget.status.textContent, '');
  await clickedAgain;
  assert.equal(view.timers.size, 1);
  view.advance(1500);
  assert.equal(widget.button.dataset.copyState, 'copied');
  assert.equal(widget.status.textContent, copies[0].copied);
  view.advance(999);
  assert.equal(widget.button.dataset.copyState, 'copied');
  view.advance(1);
  assert.equal(widget.button.dataset.copyState, undefined);
  assert.equal(widget.status.textContent, '');
});

test('each copy widget keeps an independent success reset timer', async () => {
  const view = page({ commandsByWidget: [
    { id: 'demo-install-command', text: commands, copy: copies[0] },
    { id: 'faq-install-command', text: commands, copy: copies[1] },
  ] });
  const [demo, faq] = view.widgets;
  await demo.click();
  view.advance(1000);
  await faq.click();
  assert.equal(view.timers.size, 2);
  view.advance(1500);
  assert.equal(demo.button.dataset.copyState, undefined);
  assert.equal(demo.status.textContent, '');
  assert.equal(faq.button.dataset.copyState, 'copied');
  assert.equal(faq.status.textContent, copies[1].copied);
  assert.equal(view.timers.size, 1);
  view.advance(1000);
  assert.equal(faq.button.dataset.copyState, undefined);
  assert.equal(faq.status.textContent, '');
  assert.equal(view.timers.size, 0);
});
