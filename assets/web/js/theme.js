// 主题管理:浅色/深色/跟随系统。值存 localStorage + config.ui.theme。
// 提供 XchatTheme.apply() 在 DOMContentLoaded 时跑一次,后续由 settings.js 切换。
(function () {
  if (window.XchatTheme) return;

  const STORAGE_KEY = 'xchat.theme'; // 'light' | 'dark' | 'system'

  function detectSystem() {
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
      ? 'dark' : 'light';
  }

  function effective(mode) {
    if (mode === 'light' || mode === 'dark') return mode;
    return detectSystem();
  }

  function applyTheme(mode) {
    mode = effective(mode);
    document.body.classList.remove('theme-light', 'theme-dark');
    document.body.classList.add('theme-' + mode);
    // 同步给 #theme-indicator(若已存在)
    const ind = document.getElementById('theme-indicator');
    if (ind) ind.textContent = '主题:' + mode;
  }

  function currentMode() {
    try { return localStorage.getItem(STORAGE_KEY) || 'system'; }
    catch (e) { return 'system'; }
  }

  async function setMode(mode) {
    if (!['light', 'dark', 'system'].includes(mode)) mode = 'system';
    try { localStorage.setItem(STORAGE_KEY, mode); } catch (e) {}
    applyTheme(mode);
    // 同步到后端 config(可选,失败也无所谓)
    try {
      if (window.xchat && xchat.config && xchat.config.set) {
        await xchat.config.set({ ui: { theme: mode } });
      }
    } catch (e) { /* 配置可能还没就绪,忽略 */ }
  }

  // 监听系统主题切换(mode=system 时跟随)
  let mq;
  function bindSystemListener() {
    if (!window.matchMedia) return;
    if (mq) return;
    mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = () => { if (currentMode() === 'system') applyTheme('system'); };
    if (mq.addEventListener) mq.addEventListener('change', handler);
    else if (mq.addListener) mq.addListener(handler);
  }

  // 初始化时:把 localStorage 主题与 config.json 主题合并(后者优先若存在)。
  async function initFromConfig() {
    bindSystemListener();
    let remoteMode = null;
    try {
      if (window.xchat && xchat.config && xchat.config.get) {
        const cfg = await xchat.config.get();
        if (cfg && cfg.ui && cfg.ui.theme) remoteMode = cfg.ui.theme;
      }
    } catch (e) {}
    const local = currentMode();
    const mode = remoteMode || local || 'system';
    if (mode !== local) {
      try { localStorage.setItem(STORAGE_KEY, mode); } catch (e) {}
    }
    applyTheme(mode);
  }

  window.XchatTheme = {
    apply: applyTheme,
    currentMode,
    setMode,
    initFromConfig,
  };
})();
