(() => {
  const key = 'traynook.theme';
  const darkStyle = document.getElementById('dark-theme');
  const colors = document.querySelectorAll('meta[data-theme-color]');
  let choice = 'auto';
  try {
    const saved = localStorage.getItem(key);
    if (saved === 'light' || saved === 'dark') choice = saved;
  } catch { /* System appearance remains available when storage is blocked. */ }

  function apply() {
    darkStyle.media = choice === 'auto' ? '(prefers-color-scheme: dark)' : choice === 'dark' ? 'all' : 'not all';
    document.documentElement.style.colorScheme = choice === 'auto' ? 'light dark' : choice;
    document.documentElement.dataset.theme = choice;
    colors.forEach(meta => {
      meta.media = choice === 'auto' ? `(prefers-color-scheme: ${meta.dataset.themeColor})`
        : meta.dataset.themeColor === choice ? 'all' : 'not all';
    });
  }

  // Apply the saved choice before the body paints.
  apply();
  document.addEventListener('DOMContentLoaded', () => {
    const select = document.getElementById('theme-select');
    select.value = choice;
    document.getElementById('theme-switch').hidden = false;
    select.addEventListener('change', () => {
      choice = select.value;
      apply();
      try {
        if (choice === 'auto') localStorage.removeItem(key);
        else localStorage.setItem(key, choice);
      } catch { /* The selected appearance still works for this page. */ }
    });
  });
})();
