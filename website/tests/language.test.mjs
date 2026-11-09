import assert from 'node:assert/strict';
import test from 'node:test';
import { selectLanguage } from '../src/scripts/language.mjs';

test('English is the fallback when preferences are missing or unsupported', () => {
  for (const values of [[], ['fr-FR', 'ja'], undefined, null]) assert.equal(selectLanguage(null, values), 'en');
});
test('regional browser tags resolve to supported locales', () => {
  assert.equal(selectLanguage(null, ['ru-RU']), 'ru');
  assert.equal(selectLanguage(null, ['en-GB']), 'en');
  assert.equal(selectLanguage(null, ['RU_ru']), 'ru');
});
test('browser preference order is respected', () => {
  assert.equal(selectLanguage(null, ['de-DE', 'ru', 'en']), 'ru');
  assert.equal(selectLanguage(null, ['en-US', 'ru-RU']), 'en');
});
test('an explicit saved preference overrides browser language', () => {
  assert.equal(selectLanguage('en', ['ru-RU']), 'en');
  assert.equal(selectLanguage('ru', ['en-US']), 'ru');
});
test('invalid storage and malformed browser entries are ignored', () => {
  assert.equal(selectLanguage('unsupported', [null, {}, 'ru-RU']), 'ru');
  assert.equal(selectLanguage({}, [false, 42]), 'en');
});
