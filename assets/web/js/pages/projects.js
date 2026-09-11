// 项目管理页
(function () {
  Router.on('#/projects', async function (main) {
    await render(main);
  });

  async function render(main) {
    const list = await xchat.projects.list();
    main.innerHTML = `
      <div class="row" style="margin-bottom:8px">
        <strong>项目编组</strong>
        <span class="muted">会话可隶属一个项目</span>
        <div class="grow"></div>
        <button class="btn primary" id="new">+ 新建项目</button>
      </div>
      <div id="list" class="card"></div>
    `;
    main.querySelector('#new').onclick = () => createOne(main);
    const box = main.querySelector('#list');
    if (!list.length) {
      box.innerHTML = '<div class="muted" style="padding:20px;text-align:center">无项目</div>';
      return;
    }
    box.innerHTML = list.map(p => `
      <div class="list-item" data-id="${esc(p.id)}">
        <div class="row">
          <span class="dot" style="background:${esc(p.color)}"></span>
          <strong>${esc(p.name)}</strong>
          <span class="muted">${timeAgo(p.created)}</span>
          <span class="grow"></span>
          <button class="btn" data-act="rename">重命名</button>
          <button class="btn" data-act="color">换色</button>
          <button class="btn danger" data-act="delete">删除</button>
        </div>
      </div>
    `).join('');
    box.querySelectorAll('.list-item').forEach(el => {
      const id = el.dataset.id;
      el.querySelectorAll('button').forEach(btn => {
        btn.onclick = async () => {
          const cur = list.find(x => x.id === id);
          if (!cur) return;
          if (btn.dataset.act === 'rename') {
            const n = await Modal.prompt({ title: '重命名项目', label: '新名称', value: cur.name });
            if (n === null) return;
            const t = (n || '').trim();
            if (!t) { Modal.alert({ title: '提示', message: '名称不能为空' }); return; }
            await xchat.projects.rename(id, t);
            await render(main);
          }
          if (btn.dataset.act === 'color') {
            const c = await Modal.color({ title: '换色', value: cur.color });
            if (c === null) return;
            await xchat.projects.rename(id, cur.name, c);
            await render(main);
          }
          if (btn.dataset.act === 'delete') {
            const ok = await Modal.confirm({
              title: '删除项目',
              message: '删除 "' + cur.name + '" ?隶属该项目的会话会变为未编组。',
              confirmText: '删除', danger: true,
            });
            if (!ok) return;
            await xchat.projects.delete(id);
            await render(main);
          }
        };
      });
    });
  }

  async function createOne(main) {
    const n = await Modal.prompt({ title: '新建项目', label: '项目名', placeholder: '例如:个人 / 工作' });
    if (n === null) return;
    const t = (n || '').trim();
    if (!t) { Modal.alert({ title: '提示', message: '项目名不能为空' }); return; }
    await xchat.projects.create(t);
    await render(main);
  }

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
