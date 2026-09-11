// 列表:tab 切换(全部/项目/标签)+ 搜索 + tag chip + 右键菜单
(function () {
  Router.on('#/sessions', async function (main) {
    let state = { tab: 'all', projectId: '', tag: '', q: '' };

    main.innerHTML = `
      <div class="row" style="margin-bottom:8px;gap:6px">
        <input id="q" placeholder="搜索会话..." style="flex:1">
        <button class="btn primary" id="new">+ 新建</button>
      </div>
      <div id="tabs" class="row" style="gap:6px;margin-bottom:8px;flex-wrap:wrap"></div>
      <div id="list" class="card"></div>
    `;
    main.querySelector('#q').addEventListener('input', debounce(() => {
      state.q = main.querySelector('#q').value;
      load();
    }, 300));
    main.querySelector('#new').onclick = () => Router.go('#/sessions/new');
    await refresh();

    async function refresh() {
      await renderTabs();
      await load();
    }

    async function renderTabs() {
      const projects = await xchat.projects.list();
      const tags = await xchat.sessions.listTags();
      const box = main.querySelector('#tabs');
      const tabs = [];
      tabs.push(tabBtn('all', '全部', state.tab === 'all' && !state.projectId && !state.tag));
      for (const p of projects) {
        tabs.push(tabBtn('project:' + p.id, '<span class="dot" style="background:' + esc(p.color) + '"></span>' + esc(p.name),
          state.tab === 'project' && state.projectId === p.id));
      }
      for (const t of tags) {
        tabs.push(tabBtn('tag:' + t.name, '#' + esc(t.name) + ' <span class="muted">(' + t.count + ')</span>',
          state.tab === 'tag' && state.tag === t.name));
      }
      box.innerHTML = tabs.join('');
      box.querySelectorAll('[data-tab]').forEach(el => {
        el.onclick = () => {
          const v = el.dataset.tab;
          if (v === 'all') { state.tab = 'all'; state.projectId = ''; state.tag = ''; }
          else if (v.startsWith('project:')) { state.tab = 'project'; state.projectId = v.slice('project:'.length); state.tag = ''; }
          else if (v.startsWith('tag:')) { state.tab = 'tag'; state.tag = v.slice('tag:'.length); state.projectId = ''; }
          refresh();
        };
      });
    }

    async function load() {
      const opts = {};
      if (state.tab === 'project') opts.project_id = state.projectId;
      if (state.tab === 'tag') opts.tag = state.tag;
      const list = await xchat.sessions.list(state.q, opts);
      const projects = await xchat.projects.list();
      const projMap = {};
      for (const p of projects) projMap[p.id] = p;
      const box = main.querySelector('#list');
      if (!list.length) {
        box.innerHTML = '<div class="muted" style="padding:20px;text-align:center">无会话</div>';
        return;
      }
      box.innerHTML = list.map(it => {
        const proj = it.project_id && projMap[it.project_id];
        const tagChips = (it.tags || []).slice(0, 3).map(t => '<span class="kbd">#' + esc(t) + '</span>').join(' ');
        const tagMore = (it.tags || []).length > 3 ? '<span class="muted">+' + ((it.tags || []).length - 3) + '</span>' : '';
        return `
        <div class="list-item" data-id="${it.id}">
          <div class="row">
            ${proj ? '<span class="dot" style="background:' + esc(proj.color) + '"></span>' : ''}
            <strong>${esc(it.title)}</strong>
            <span class="grow"></span>
            ${tagChips}${tagMore}
          </div>
          <div class="muted">${esc(it.provider_id || '')} · ${esc(it.model_id || '')} · tokens ${it.total_input + it.total_output} · ${timeAgo(it.updated)}</div>
        </div>
      `;
      }).join('');
      box.querySelectorAll('.list-item').forEach(el => {
        const id = el.dataset.id;
        el.addEventListener('click', () => Router.go('#/chat/' + id));
        el.addEventListener('contextmenu', e => { e.preventDefault(); showMenu(e, id); });
        let pressTimer;
        el.addEventListener('touchstart', () => { pressTimer = setTimeout(() => showMenuAt(el, id), 600); });
        el.addEventListener('touchend', () => clearTimeout(pressTimer));
      });
    }

    async function showMenu(e, id) {
      const session = await xchat.sessions.get(id).catch(() => null);
      const projects = await xchat.projects.list();
      const tagList = await xchat.sessions.listTags();
      const projBtns = projects.map(p => '<div class="btn" data-proj="' + esc(p.id) + '">' +
        (p.id === (session && session.project_id) ? '✓ ' : '') + esc(p.name) + '</div>').join('');
      const tagBtns = tagList.map(t => '<div class="btn" data-addtag="' + esc(t.name) + '">#' + esc(t.name) + '</div>').join('');

      const menu = document.createElement('div');
      menu.className = 'card';
      menu.style.cssText = 'position:fixed;left:' + e.clientX + 'px;top:' + e.clientY + 'px;z-index:300;padding:6px;min-width:220px';
      menu.innerHTML = `
        <div class="btn" data-act="clone">克隆(含历史)</div>
        <div class="btn" data-act="cloneMeta">以此建新会话</div>
        <div class="btn" data-act="editor">编辑器打开</div>
        <div class="btn" data-act="tags">设置标签…</div>
        <div class="btn" data-act="project">移到项目…</div>
        <div class="btn danger" data-act="delete">删除</div>
      `;
      document.body.appendChild(menu);
      const close = () => document.body.removeChild(menu);
      menu.addEventListener('click', async ev => {
        const t = ev.target;
        const act = t.dataset.act;
        if (act === 'clone') {
          close();
          await xchat.sessions.clone(id);
          await refresh();
        }
        if (act === 'cloneMeta') {
          close();
          // 以此会话的 chat 属性/meta/system/tools/项目/标签建新会话,
          // 不带历史消息。直接跳转。
          const res = await xchat.sessions.cloneMeta(id);
          Router.go('#/chat/' + res.id);
        }
        if (act === 'editor') {
          close();
          await xchat.sessions.openInEditor(id);
        }
        if (act === 'delete') {
          close();
          const ok = await Modal.confirm({ title: '删除会话', message: '删除该会话?不可撤销。', confirmText: '删除', danger: true });
          if (ok) {
            await xchat.sessions.delete(id);
            await refresh();
          }
        }
        if (act === 'tags') {
          close();
          const cur = (session && session.tags) || [];
          const inp = await Modal.prompt({
            title: '设置标签',
            message: '逗号或空格分隔,小写',
            label: '标签',
            value: cur.join(', '),
          });
          if (inp === null) return;
          const tags = inp.split(/[,\s]+/).map(s => s.trim().toLowerCase()).filter(Boolean);
          await xchat.sessions.setTags(id, tags);
          await refresh();
        }
        if (act === 'project') {
          close();
          const choices = [{ value: '', label: '(无 · 移出)' }].concat(projects.map(p => ({
            value: p.id, label: p.name + (session && session.project_id === p.id ? ' (当前)' : ''),
          })));
          const v = await Modal.prompt({
            title: '移到项目',
            label: '选择项目',
            choices,
            value: session ? (session.project_id || '') : '',
            allowEmpty: false,
          });
          if (v === null) return;
          await xchat.sessions.setProject(id, v.trim() || null);
          await refresh();
        }
      });
      setTimeout(close, 8000);
    }
    function showMenuAt(el, id) {
      const r = el.getBoundingClientRect();
      showMenu({ clientX: r.left, clientY: r.bottom }, id);
    }
  });

  function tabBtn(value, label, active) {
    return '<div class="btn' + (active ? ' primary' : '') + '" data-tab="' + esc(value) + '">' + label + '</div>';
  }
  function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function timeAgo(iso) {
    const d = new Date(iso); const sec = (Date.now() - d.getTime()) / 1000;
    if (sec < 60) return '刚刚';
    if (sec < 3600) return Math.floor(sec / 60) + '分钟前';
    if (sec < 86400) return Math.floor(sec / 3600) + '小时前';
    return Math.floor(sec / 86400) + '天前';
  }
})();
