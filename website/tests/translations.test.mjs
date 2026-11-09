import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const en = JSON.parse(readFileSync(new URL('../src/i18n/en.json', import.meta.url)));
const ru = JSON.parse(readFileSync(new URL('../src/i18n/ru.json', import.meta.url)));
const flatten = (value, prefix = '') => typeof value === 'string' ? { [prefix]: value }
  : Object.assign({}, ...Object.entries(value).map(([key, child]) => flatten(child, `${prefix}.${key}`)));
const english = flatten(en);
const russian = flatten(ru);
const matches = (text, pattern) => [...text.matchAll(pattern)].map(match => match[0]).sort();

test('catalogues have identical keys, FAQ order, and nonempty strings', () => {
  assert.deepEqual(Object.keys(russian).sort(), Object.keys(english).sort());
  for (const [key, value] of Object.entries(russian)) assert.ok(value.trim(), key);
  assert.deepEqual(ru.faq.items.map(item => item.id), en.faq.items.map(item => item.id));
});
test('dynamic message placeholders are preserved', () => {
  for (const key of Object.keys(english)) {
    assert.deepEqual(matches(russian[key], /\{\w+\}/g), matches(english[key], /\{\w+\}/g), key);
  }
});
test('translated rich copy preserves links, HTML structure, and numeric facts', () => {
  for (const key of Object.keys(english)) {
    assert.deepEqual(matches(russian[key], /https:\/\/[^"\s<]+/g), matches(english[key], /https:\/\/[^"\s<]+/g), key);
    assert.deepEqual(matches(russian[key], /<[^>]+>/g), matches(english[key], /<[^>]+>/g), key);
    assert.deepEqual(matches(russian[key], /\d+(?:\.\d+)*/g), matches(english[key], /\d+(?:\.\d+)*/g), key);
  }
});
test('native app labels stay accurate while website and example names are localized', () => {
  for (const key of ['file', 'edit', 'settings', 'layout', 'menu', 'dropdown', 'hidden', 'preview', 'empty']) {
    assert.equal(ru.demo[key], en.demo[key], key);
  }
  for (const key of ['meta.title', 'hero.line1', 'hero.description', 'nav.skip', 'demo.itemNames.timer', 'demo.moved']) {
    assert.match(russian[`.${key}`], /[А-Яа-яЁё]/, key);
  }
});
