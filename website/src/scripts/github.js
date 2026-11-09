(async () => {
  const stats = document.querySelector('[data-repo-stats]');
  if (!stats) return;
  try {
    const response = await fetch('https://api.github.com/repos/TrayNook/traynook', {
      headers: { Accept: 'application/vnd.github+json' },
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error('Repository counts unavailable');
    const data = await response.json();
    const counts = { stars: data.stargazers_count, forks: data.forks_count };
    if (!Object.values(counts).every(value => Number.isSafeInteger(value) && value >= 0)) {
      throw new Error('Invalid repository counts');
    }
    const format = new Intl.NumberFormat(document.documentElement.lang, { notation: 'compact', maximumFractionDigits: 1 });
    for (const [name, value] of Object.entries(counts)) {
      const counter = stats.querySelector(`[data-repo-count="${name}"]`);
      counter.textContent = format.format(value);
      counter.hidden = false;
    }
  } catch {
    stats.querySelector('[data-stats-unavailable]').hidden = false;
  }
})();
