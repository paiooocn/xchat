// hash 路由：支持字符串与正则
window.Router = (function() {
  const routes = []; // [{pattern, handler}]
  let app;
  function init() {
    app = document.getElementById('app');
    window.addEventListener('hashchange', () => render(location.hash));
  }
  function on(pattern, handler) {
    if (pattern instanceof RegExp) routes.push({regex: pattern, handler});
    else routes.push({regex: new RegExp('^' + pattern.replace(/:[^/]+/g, '([^/]+)') + '$'), handler});
  }
  function go(hash) { location.hash = hash; render(hash); }
  async function render(hash) {
    let match = null, handler = null, params = [];
    for (const r of routes) {
      const m = hash.match(r.regex);
      if (m) { match = m; handler = r.handler; params = m.slice(1); break; }
    }
    if (!handler) { location.hash = '#/sessions'; return; }
    app.innerHTML = '<div class="topbar"><h1>XChat</h1><a href="#/sessions">会话</a><a href="#/projects">项目</a><a href="#/templates">模板</a><a href="#/providers">Providers</a><a href="#/cost">成本</a><a href="#/settings">设置</a><div class="grow"></div><span id="theme-indicator" class="muted"></span></div><div id="main" class="main"></div>';
    // 每次路由切换都把当前主题同步到 indicator
    if (window.XchatTheme) {
      const ind = document.getElementById('theme-indicator');
      if (ind) ind.textContent = '主题:' + XchatTheme.currentMode();
    }
    const main = document.getElementById('main');
    main.innerHTML = '<div class="muted">加载中…</div>';
    try {
      await handler(main, match, params);
    } catch (e) {
      // e 可能是 {error:'xxx'} 对象,也可能是 Error
      var msg = (e && (e.error || e.message)) || (typeof e === 'string' ? e : JSON.stringify(e));
      main.innerHTML = '<div class="toast error">' + msg + '</div>';
    }
  }
  return { init, on, go };
})();
