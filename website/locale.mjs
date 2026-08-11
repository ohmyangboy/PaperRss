export function resolveWebsiteLocale(storedLocale, browserLanguages = []) {
  if (storedLocale === 'zh-CN' || storedLocale === 'en') return storedLocale;
  const primaryLanguage = browserLanguages.find(Boolean)?.toLowerCase() ?? '';
  return primaryLanguage.startsWith('en') ? 'en' : 'zh-CN';
}
