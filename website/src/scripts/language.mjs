export const LANGUAGE_KEY = 'traynook.language';

export function selectLanguage(saved, languages = []) {
  const supported = value => {
    if (typeof value !== 'string') return undefined;
    const base = value.toLowerCase().split(/[-_]/)[0];
    return ['en', 'ru'].includes(base) ? base : undefined;
  };
  return supported(saved) || (Array.isArray(languages) && languages.map(supported).find(Boolean)) || 'en';
}

if (typeof document !== 'undefined') {
  document.querySelectorAll('[data-language]').forEach(link => {
    link.addEventListener('click', () => {
      try { localStorage.setItem(LANGUAGE_KEY, link.dataset.language); }
      catch { /* The language links still work when storage is unavailable. */ }
    });
  });
  if (document.documentElement.dataset.detectLanguage) {
    let saved;
    try { saved = localStorage.getItem(LANGUAGE_KEY); }
    catch { /* Browser preferences still work when storage is unavailable. */ }
    const language = selectLanguage(saved, navigator.languages?.length ? navigator.languages : [navigator.language]);
    location.replace(`${document.documentElement.dataset.base}${language}/${location.search}${location.hash}`);
  }
}
