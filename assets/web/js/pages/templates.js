// 模板管理:内置 + 用户模板,带列表 / 查看 / 编辑 / 复制 / 删除 / 外部编辑器打开
// 新建流程:进入编辑页时只在内存里维护草稿,点 [保存] 才写盘;
//          点 [返回] 直接丢弃,不创建空模板文件。
(function () {
  Router.on('#/templates', async function (main) {
    await renderList(main);
  });

  async function renderList(main) {
    const list = await xchat.templates.list();
    main.innerHTML = `
      <div class="row" style="margin-bottom:12px">
        <strong>模板管理</strong>
        <span class="muted">内置只读,用户模板可编辑/删除</span>
        <div class="grow"></div>
        <button class="btn primary" id="new">+ 新建模板</button>
      </div>
      <div id="list" class="card"></div>
    `;
    main.querySelector('#new').onclick = () => editTemplate(main, null);
    const box = main.querySelector('#list');
    box.innerHTML = list.map(t => `
      <div class="list-item" data-id="${esc(t.id)}">
        <div class="row">
          <strong>${esc(t.name)}</strong>
          ${t.editable ? '<span class="kbd">user</span>' : '<span class="kbd">builtin</span>'}
          <span class="muted">${esc(t.description || '')}</span>
        </div>
        <div class="muted">变量: ${t.vars.length ? t.vars.map(v => '<span class="kbd">{{'+esc(v)+'}}</span>').join(' ') : '(无)'}</div>
        <div class="row" style="margin-top:6px;gap:6px;flex-wrap:wrap">
          <button class="btn" data-act="view">查看</button>
          <button class="btn" data-act="edit">编辑</button>
          <button class="btn" data-act="copy">复制为我的</button>
          ${t.editable ? '<button class="btn" data-act="editor">编辑器打开</button>' : ''}
          ${t.editable ? '<button class="btn danger" data-act="delete">删除</button>' : ''}
        </div>
      </div>
    `).join('');
    box.querySelectorAll('.list-item').forEach(el => {
      const id = el.dataset.id;
      el.querySelectorAll('button').forEach(btn => {
        btn.onclick = async () => {
          const act = btn.dataset.act;
          if (act === 'view') return viewTemplate(main, id);
          if (act === 'edit') return editTemplate(main, id);
          if (act === 'copy') return copyTemplate(main, id);
          if (act === 'editor') return xchat.templates.openInEditor(id);
          if (act === 'delete') return deleteTemplate(main, id);
        };
      });
    });
  }

  // ---- 查看模板原文(内置/用户都可) ----
  async function viewTemplate(main, id) {
    let t;
    try { t = await xchat.templates.get(id); }
    catch (e) {
      Modal.alert({ title: '加载失败', message: (e && (e.error || e.message)) || JSON.stringify(e) });
      return;
    }
    if (!t) { Modal.alert({ title: '未找到', message: '模板不存在: ' + id }); return; }
    Modal.view({
      title: '模板原文 · ' + t.name + (t.editable ? '' : ' (内置)'),
      message: 'id: ' + t.id + (t.description ? ' · ' + t.description : ''),
      body: t.xml,
    });
  }

  async function copyTemplate(main, id) {
    const t = await xchat.templates.get(id);
    if (!t) { Modal.alert({ title: '未找到', message: '模板不存在' }); return; }
    const name = await Modal.prompt({
      title: '复制模板',
      label: '新模板名',
      value: (t.name || '') + ' (副本)',
      placeholder: '输入新模板名',
    });
    if (name === null) return;
    const trimmed = (name || '').trim();
    if (!trimmed) { Modal.alert({ title: '提示', message: '模板名不能为空' }); return; }
    try {
      const created = await xchat.templates.duplicate(id, trimmed);
      toast('已复制为 ' + created.id, 'ok');
      await renderList(main);
    } catch (e) {
      Modal.alert({ title: '复制失败', message: (e && (e.error || e.message)) || JSON.stringify(e) });
    }
  }

  async function deleteTemplate(main, id) {
    const t = await xchat.templates.get(id);
    if (!t) { Modal.alert({ title: '未找到', message: '模板不存在' }); return; }
    const ok = await Modal.confirm({
      title: '删除模板',
      message: '确认删除 "' + (t.name || id) + '" ?此操作不可撤销。',
      confirmText: '删除',
      danger: true,
    });
    if (!ok) return;
    try {
      await xchat.templates.delete(id);
      toast('已删除 ' + id, 'ok');
      await renderList(main);
    } catch (e) {
      Modal.alert({ title: '删除失败', message: (e && (e.error || e.message)) || JSON.stringify(e) });
    }
  }

  // ---- 编辑模板 ----
  // id 为 null 表示新建:不预先持久化,只在内存里编辑草稿,点 [保存] 才落盘。
  // 返回列表时不创建文件,直接丢弃草稿。
  async function editTemplate(main, id) {
    let t;
    if (id) {
      t = await xchat.templates.get(id);
      if (!t) { main.innerHTML = '<div class="muted">未找到</div>'; return; }
      if (!t.editable) {
        const ok = await Modal.confirm({
          title: '内置模板',
          message: '"' + t.name + '" 是内置模板,只读。是否复制为我的模板再编辑?',
          confirmText: '复制并编辑',
        });
        if (!ok) return;
        const name = await Modal.prompt({
          title: '复制模板',
          label: '新模板名',
          value: t.name + ' (副本)',
        });
        if (name === null) return;
        const created = await xchat.templates.duplicate(id, name.trim());
        return editTemplate(main, created.id);
      }
    } else {
      // 新建:仅在内存中构造草稿,不写盘
      const emptyXml = `<?xml version="1.0" encoding="UTF-8"?>
<template name="新模板" description="">
<meta><max_rounds value="20"/></meta>
<system><![CDATA[
]]></system>
<tools/>
</template>`;
      t = {
        id: '',                       // 空 id 表示未保存
        name: '新模板',
        description: '',
        xml: emptyXml,
        vars: [],
        editable: true,
        _isNew: true,
      };
    }

    main.innerHTML = `
      <div class="row" style="margin-bottom:8px">
        <button class="btn" id="back">← 返回</button>
        <strong id="title">${t._isNew ? '新建模板(未保存)' : '编辑模板'}</strong>
        <span class="muted" id="idlabel"></span>
      </div>
      <div class="field"><label>名称</label><input id="name" value="${esc(t.name)}"></div>
      <div class="field"><label>描述</label><input id="desc" value="${esc(t.description || '')}"></div>
      <div class="field"><label>XML <span class="muted">(用 {{var}} 声明变量)</span></label>
        <textarea id="xml" style="width:100%;min-height:340px;font-family:monospace;font-size:13px">${esc(t.xml)}</textarea>
      </div>
      <div class="muted" id="vars"></div>
      <div class="row" style="margin-top:12px;justify-content:flex-end;gap:6px">
        ${t._isNew ? '' : '<button class="btn" id="editor">外部编辑器</button>'}
        ${t._isNew ? '' : '<button class="btn" id="reload">重新读取文件</button>'}
        <button class="btn" id="cancelBtn">放弃</button>
        <button class="btn primary" id="save">保存</button>
      </div>
    `;
    main.querySelector('#idlabel').textContent = t.id ? ('id: ' + t.id) : '(尚未保存)';
    main.querySelector('#back').onclick = () => confirmLeave(main, t, renderList);
    main.querySelector('#cancelBtn').onclick = () => confirmLeave(main, t, renderList);
    const ed = main.querySelector('#editor'); if (ed) ed.onclick = () => xchat.templates.openInEditor(id);
    const rl = main.querySelector('#reload'); if (rl) rl.onclick = async () => {
      const fresh = await xchat.templates.get(id);
      main.querySelector('#xml').value = fresh.xml;
      refreshVars();
    };
    main.querySelector('#save').onclick = async () => {
      const xml = main.querySelector('#xml').value;
      const name = main.querySelector('#name').value.trim() || '未命名';
      const description = main.querySelector('#desc').value.trim();
      try {
        const saved = await xchat.templates.save({
          id: t._isNew ? undefined : id,
          name, description, xml,
        });
        toast('已保存 ' + saved.id, 'ok');
        // 标为已保存,后续 back 直接走
        t._dirty = false;
        await renderList(main);
      } catch (e) {
        Modal.alert({ title: '保存失败', message: (e && (e.error || e.message)) || JSON.stringify(e) });
      }
    };
    const refreshVars = () => {
      const xml = main.querySelector('#xml').value;
      const re = /\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/g;
      const set = new Set();
      let m;
      while ((m = re.exec(xml))) set.add(m[1]);
      const arr = [...set].sort();
      main.querySelector('#vars').innerHTML = arr.length
        ? '变量: ' + arr.map(v => `<span class="kbd">{{${esc(v)}}}</span>`).join(' ')
        : '变量: (无)';
    };
    main.querySelector('#xml').addEventListener('input', () => { t._dirty = true; refreshVars(); });
    refreshVars();
  }

  async function confirmLeave(main, t, onLeave) {
    if (t._isNew && !t._dirty) { onLeave(main); return; }
    // 已保存的模板:任何时候离开都直接走(后端文件没动)
    if (!t._isNew) { onLeave(main); return; }
    const choice = await Modal.prompt({
      title: '尚未保存',
      message: '当前模板还未保存,直接离开会丢弃编辑。',
      label: '操作',
      choices: [
        { value: 'save', label: '保存并离开' },
        { value: 'discard', label: '丢弃并离开' },
        { value: 'cancel', label: '留在编辑页' },
      ],
      value: 'save',
    });
    if (choice === 'cancel' || choice === null) return;
    if (choice === 'save') {
      main.querySelector('#save').click();
      // 保存成功后会自己 renderList;若失败(弹窗),留在原页
    } else {
      onLeave(main);
    }
  }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function toast(msg, type) {
    const t = document.createElement('div');
    t.className = 'toast ' + (type || '');
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(() => document.body.removeChild(t), 2500);
  }
})();
