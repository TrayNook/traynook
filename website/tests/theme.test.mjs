import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../src/scripts/theme.js', import.meta.url), 'utf8');

function page({ saved = null, blockRead = false, blockWrite = false } = {}) {
  const values = new Map([['other.preference', 'preserved']]);
  if (saved !== null) values.set('traynook.theme', saved);
  const root = { style: {}, dataset: {} };
  const darkStyle = { media: '(prefers-color-scheme: dark)' };
  const colors = ['light', 'dark'].map(themeColor => ({ dataset: { themeColor }, media: '' }));
  const switcher = { hidden: true };
  let onChange;
  const select = { value: 'auto', addEventListener(type, callback) {
    assert.equal(type, 'change');
    onChange = callback;
  } };
  const nodes = { 'dark-theme': darkStyle, 'theme-select': select, 'theme-switch': switcher };
  let onReady;
  runInNewContext(script, {
    document: {
      documentElement: root,
      getElementById: id => nodes[id],
      querySelectorAll(selector) {
        assert.equal(selector, 'meta[data-theme-color]');
        return colors;
      },
      addEventListener(type, callback) {
        assert.equal(type, 'DOMContentLoaded');
        onReady = callback;
      },
    },
    localStorage: {
      getItem(key) {
        if (blockRead) throw new Error('Storage is blocked');
        return values.get(key) ?? null;
      },
      setItem(key, value) {
        if (blockWrite) throw new Error('Storage is blocked');
        values.set(key, value);
      },
      removeItem(key) {
        if (blockWrite) throw new Error('Storage is blocked');
        values.delete(key);
      },
    },
  }, { filename: 'theme.js' });
  return {
    root, darkStyle, colors, select, switcher, values,
    ready: () => onReady(),
    choose(value) { select.value = value; onChange(); },
  };
}

function assertTheme(view, theme) {
  assert.equal(view.root.dataset.theme, theme);
  assert.equal(view.root.style.colorScheme, theme === 'auto' ? 'light dark' : theme);
  assert.equal(view.darkStyle.media, theme === 'auto' ? '(prefers-color-scheme: dark)' : theme === 'dark' ? 'all' : 'not all');
  for (const meta of view.colors) {
    assert.equal(meta.media, theme === 'auto' ? `(prefers-color-scheme: ${meta.dataset.themeColor})`
      : meta.dataset.themeColor === theme ? 'all' : 'not all');
  }
}

test('missing and unsupported preferences follow system appearance through CSS media queries', () => {
  for (const saved of [null, '', 'auto', 'sepia', 'DARK']) assertTheme(page({ saved }), 'auto');
});

test('saved light and dark choices apply before the page controls are ready', () => {
  for (const saved of ['light', 'dark']) {
    const view = page({ saved });
    assertTheme(view, saved);
    assert.equal(view.switcher.hidden, true);
    view.ready();
    assert.equal(view.select.value, saved);
    assert.equal(view.switcher.hidden, false);
  }
});

test('manual changes persist and Auto clears only the theme preference', () => {
  const view = page();
  view.ready();
  assert.equal(view.select.value, 'auto');
  for (const choice of ['dark', 'light']) {
    view.choose(choice);
    assertTheme(view, choice);
    assert.equal(view.values.get('traynook.theme'), choice);
  }
  view.choose('auto');
  assertTheme(view, 'auto');
  assert.equal(view.values.has('traynook.theme'), false);
  assert.equal(view.values.get('other.preference'), 'preserved');
});

test('a blocked storage read falls back to Auto and leaves the controls usable', () => {
  const view = page({ saved: 'dark', blockRead: true, blockWrite: true });
  assertTheme(view, 'auto');
  view.ready();
  assert.equal(view.select.value, 'auto');
  assert.equal(view.switcher.hidden, false);
  view.choose('dark');
  assertTheme(view, 'dark');
});

test('blocked storage writes do not prevent manual switching or returning to Auto', () => {
  const view = page({ saved: 'dark', blockWrite: true });
  view.ready();
  for (const choice of ['light', 'auto', 'dark']) {
    view.choose(choice);
    assertTheme(view, choice);
  }
  assert.equal(view.values.get('traynook.theme'), 'dark');
});
