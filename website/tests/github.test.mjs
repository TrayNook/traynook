import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../src/scripts/github.js', import.meta.url), 'utf8');

async function page({ lang = 'en', present = true, data = { stargazers_count: 12, forks_count: 3 }, ok = true, fetchError, jsonError } = {}) {
  const counts = Object.fromEntries(['stars', 'forks'].map(name => [name, { textContent: '', hidden: true }]));
  const unavailable = { hidden: true };
  const requests = [];
  let jsonCalls = 0;
  const stats = {
    querySelector(selector) {
      if (selector === '[data-stats-unavailable]') return unavailable;
      const name = /^\[data-repo-count="(stars|forks)"\]$/.exec(selector)?.[1];
      assert.ok(name, `Unexpected selector: ${selector}`);
      return counts[name];
    },
  };
  await runInNewContext(script, {
    document: {
      documentElement: { lang },
      querySelector(selector) {
        assert.equal(selector, '[data-repo-stats]');
        return present ? stats : null;
      },
    },
    fetch: async (url, options) => {
      requests.push({ url, options });
      if (fetchError) throw fetchError;
      return {
        ok,
        json: async () => {
          jsonCalls++;
          if (jsonError) throw jsonError;
          return data;
        },
      };
    },
    Intl,
    AbortSignal,
  }, { filename: 'github.js' });
  return { counts, unavailable, requests, jsonCalls };
}

function assertUnavailable(view) {
  for (const counter of Object.values(view.counts)) {
    assert.equal(counter.hidden, true);
    assert.equal(counter.textContent, '');
  }
  assert.equal(view.unavailable.hidden, false);
}

test('valid counts including zero are displayed without treating zero as missing', async () => {
  const view = await page({ data: { stargazers_count: 0, forks_count: 0 } });
  for (const counter of Object.values(view.counts)) {
    assert.equal(counter.textContent, '0');
    assert.equal(counter.hidden, false);
  }
  assert.equal(view.unavailable.hidden, true);
});

test('counts use compact formatting in the page language', async () => {
  for (const lang of ['en', 'ru']) {
    const view = await page({ lang, data: { stargazers_count: 1250, forks_count: 34567 } });
    const format = new Intl.NumberFormat(lang, { notation: 'compact', maximumFractionDigits: 1 });
    assert.equal(view.counts.stars.textContent, format.format(1250));
    assert.equal(view.counts.forks.textContent, format.format(34567));
    assert.equal(view.counts.stars.hidden, false);
    assert.equal(view.counts.forks.hidden, false);
    assert.equal(view.unavailable.hidden, true);
  }
});

test('only the fixed public repository endpoint is requested without credentials or referrer', async () => {
  const view = await page();
  assert.equal(view.requests.length, 1);
  const { url, options } = view.requests[0];
  assert.equal(url, 'https://api.github.com/repos/TrayNook/traynook');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.referrerPolicy, 'no-referrer');
  assert.equal(options.headers.Accept, 'application/vnd.github+json');
  assert.ok(options.signal instanceof AbortSignal);
  assert.equal(view.jsonCalls, 1);
});

test('HTTP and malformed JSON failures reveal the fallback without showing counts', async () => {
  const httpFailure = await page({ ok: false });
  assertUnavailable(httpFailure);
  assert.equal(httpFailure.jsonCalls, 0);
  assertUnavailable(await page({ jsonError: new SyntaxError('Invalid JSON') }));
});

test('missing, negative, string, fractional and unsafe counts cannot produce partial or invented stats', async () => {
  for (const data of [null, {}, [], { stargazers_count: 1 }, { forks_count: 1 }]) {
    assertUnavailable(await page({ data }));
  }
  for (const invalid of [-1, '12', 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assertUnavailable(await page({ data: { stargazers_count: invalid, forks_count: 3 } }));
    assertUnavailable(await page({ data: { stargazers_count: 12, forks_count: invalid } }));
  }
});

test('network and timeout rejections are handled through the accessible fallback', async () => {
  for (const fetchError of [new TypeError('Network unavailable'), new DOMException('Request timed out', 'TimeoutError')]) {
    assertUnavailable(await page({ fetchError }));
  }
});

test('pages without repository stats make no request', async () => {
  const view = await page({ present: false });
  assert.equal(view.requests.length, 0);
  assert.equal(view.unavailable.hidden, true);
  assert.equal(view.jsonCalls, 0);
});
