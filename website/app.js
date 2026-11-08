const translated = [...document.querySelectorAll('[data-ko]')];
translated.forEach(el => { el.dataset.en = el.innerHTML; });
const languageButton = document.querySelector('#language');
function setLanguage(lang) {
  document.documentElement.lang = lang;
  translated.forEach(el => { el.innerHTML = el.dataset[lang]; });
  languageButton.textContent = lang === 'ko' ? 'English' : '한국어';
  languageButton.setAttribute('aria-label', lang === 'ko' ? 'Switch to English' : '한국어로 전환');
  document.title = lang === 'ko' ? 'rufus4mac — 새로운 시작. 당신의 Mac에서.' : 'rufus4mac — A fresh start. From your Mac.';
  try { localStorage.setItem('rufus4mac-site-language', lang); } catch { /* Storage is optional. */ }
}
let initialLanguage = navigator.language.startsWith('ko') ? 'ko' : 'en';
try { const saved = localStorage.getItem('rufus4mac-site-language'); if (['en', 'ko'].includes(saved)) initialLanguage = saved; } catch { /* Use browser language. */ }
setLanguage(initialLanguage);
languageButton.addEventListener('click', () => setLanguage(document.documentElement.lang === 'en' ? 'ko' : 'en'));
const tabs = [...document.querySelectorAll('[role=tab]')];
function selectTask(tab) {
  tabs.forEach(item => {
    const active = item === tab;
    item.classList.toggle('active', active);
    item.setAttribute('aria-selected', String(active));
    item.tabIndex = active ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !active;
  });
}
tabs.forEach((tab, i) => {
  tab.addEventListener('click', () => selectTask(tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowDown') next = (i + 1) % tabs.length;
    if (event.key === 'ArrowUp') next = (i + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) { event.preventDefault(); selectTask(tabs[next]); tabs[next].focus(); }
  });
});
