// 会话新建:单页表单,默认填好后一键创建。
// 布局:模板(卡片列表) → 模板参数(若模板声明了 {{var}})/Provider/Model → 高级(sandbox/maxRounds/项目/标签,可折叠)。
(function () {
  Router.on('#/sessions/new', async function (main) {
    const state = {
      template_id: '',
      vars: {},
      provider_id: '',
      model_id: '',
      sandbox: '/tmp',
      max_rounds: 20,
      project_id: '',
      tags: [],
      advancedOpen: false,
    };
    const [templates, config, projects] = await Promise.all([
      xchat.sessions.listTemplates(),
      xchat.config.get(),
      xchat.projects.list(),
    ]);
    const providers = (config && config.providers) || [];
    // 默认选第一个 provider / 第一个 model
    if (!state.provider_id && providers.length) {
      state.provider_id = providers[0].id;
      if (providers[0].models && providers[0].models.length) {
        state.model_id = providers[0].models[0].id;
      }
    }
    // 尝试优先 builtin:coder / builtin:research 作为默认模板
    if (!state.template_id) {
      const t = templates.find(t => t.id === 'builtin:coder') || templates[0];
      if (t) state.template_id = t.id;
    }

    function render() {
      main.innerHTML = `
        <div class="row" style="margin-bottom:8px">
          <a href="#/sessions" class="btn">← 返回</a>
          <strong>新建会话</strong>
          <span class="muted">选模板 + 选模型,一键创建</span>
        </div>
        <div class="card" style="margin-bottom:10px">
          <div class="row" style="margin-bottom:6px"><strong>1. 模板</strong><span class="muted">决定系统提示与默认工具集</span></div>
          <div id="tpl-list">${renderTplList()}</div>
        </div>
        <div class="card" style="margin-bottom:10px">
          <div class="row" style="margin-bottom:6px"><strong>2. Provider / Model</strong></div>
          <div class="row" style="gap:8px;flex-wrap:wrap">
            <div class="field" style="flex:1;min-width:200px;margin-bottom:0">
              <select id="prov">${providers.map(p => `<option value="${esc(p.id)}" ${p.id === state.provider_id ? 'selected' : ''}>${esc(p.id)} (${esc(p.type)})</option>`).join('')}</select>
            </div>
            <div class="field" style="flex:1;min-width:200px;margin-bottom:0">
              <select id="model">${renderModelOpts()}</select>
            </div>
          </div>
          <div id="var-fields" style="margin-top:8px">${renderVarFields()}</div>
        </div>
        <div class="card" style="margin-bottom:10px">
          <div class="row" style="cursor:pointer" id="adv-toggle">
            <strong>3. 高级</strong>
            <span class="muted">${state.advancedOpen ? '点击收起' : 'sandbox / max_rounds / 项目 / 标签'}</span>
            <span class="grow"></span>
            <span class="muted">${state.advancedOpen ? '▲' : '▼'}</span>
          </div>
          <div id="adv-body" style="${state.advancedOpen ? '' : 'display:none;'}margin-top:8px">
            <div class="row" style="gap:8px;flex-wrap:wrap">
              <div class="field" style="flex:1;min-width:180px;margin-bottom:8px">
                <label>Sandbox 路径</label>
                <input id="sb" value="${esc(state.sandbox)}">
              </div>
              <div class="field" style="width:140px;margin-bottom:8px">
                <label>Max Rounds</label>
                <input id="mr" type="number" min="1" value="${state.max_rounds}">
              </div>
            </div>
            <div class="row" style="gap:8px;flex-wrap:wrap">
              <div class="field" style="flex:1;min-width:180px;margin-bottom:8px">
                <label>项目</label>
                <select id="proj">
                  <option value="">(无)</option>
                  ${projects.map(p => `<option value="${esc(p.id)}" ${p.id === state.project_id ? 'selected' : ''}>${esc(p.name)}</option>`).join('')}
                </select>
              </div>
              <div class="field" style="flex:1;min-width:180px;margin-bottom:8px">
                <label>标签(逗号或空格分隔)</label>
                <input id="tags" value="${esc((state.tags || []).join(', '))}">
              </div>
            </div>
          </div>
        </div>
        <div class="row" style="justify-content:flex-end;gap:6px">
          <a href="#/sessions" class="btn">取消</a>
          <button class="btn primary" id="create">创建会话</button>
        </div>
      `;
      bind();
    }

    function renderTplList() {
      if (!templates.length) return '<div class="muted">无可用模板</div>';
      return templates.map(t => `
        <div class="list-item${t.id === state.template_id ? ' sel' : ''}" data-id="${esc(t.id)}" style="display:flex;gap:8px;align-items:center">
          <span class="kbd">${esc(t.id.startsWith('builtin:') ? '内置' : '我的')}</span>
          <div style="flex:1;min-width:0">
            <div><strong>${esc(t.name)}</strong></div>
            <div class="muted">${esc(t.description || '')}</div>
          </div>
        </div>
      `).join('');
    }
    function renderModelOpts() {
      const p = providers.find(x => x.id === state.provider_id);
      const models = (p && p.models) || [];
      if (!models.length) return '<option value="">(无模型)</option>';
      return models.map(m => `<option value="${esc(m.id)}" ${m.id === state.model_id ? 'selected' : ''}>${esc(m.id)}</option>`).join('');
    }
    function renderVarFields() {
      const t = templates.find(x => x.id === state.template_id);
      const vs = (t && t.vars) || [];
      if (!vs.length) return '';
      return '<div class="muted" style="margin-bottom:4px">模板参数</div>' + vs.map(v => `
        <div class="field" style="margin-bottom:6px">
          <label>{{${esc(v)}}}</label>
          <input data-var="${esc(v)}" value="${esc(state.vars[v] || (v === 'sandbox' ? state.sandbox : '') || '')}" placeholder="${esc(v === 'sandbox' ? '/tmp' : '')}">
        </div>
      `).join('');
    }

    function bind() {
      main.querySelectorAll('#tpl-list .list-item').forEach(el => {
        el.onclick = () => {
          state.template_id = el.dataset.id;
          // 重置模板参数默认值
          const t = templates.find(x => x.id === state.template_id);
          state.vars = {};
          render();
        };
      });
      const prov = main.querySelector('#prov');
      if (prov) prov.onchange = () => {
        state.provider_id = prov.value;
        const p = providers.find(x => x.id === state.provider_id);
        state.model_id = p && p.models && p.models[0] ? p.models[0].id : '';
        render();
      };
      const mod = main.querySelector('#model');
      if (mod) mod.onchange = () => { state.model_id = mod.value; };
      main.querySelectorAll('input[data-var]').forEach(inp => {
        inp.oninput = () => { state.vars[inp.dataset.var] = inp.value; };
      });
      const adv = main.querySelector('#adv-toggle');
      if (adv) adv.onclick = () => { state.advancedOpen = !state.advancedOpen; render(); };
      const sb = main.querySelector('#sb'); if (sb) sb.oninput = () => { state.sandbox = sb.value; };
      const mr = main.querySelector('#mr'); if (mr) mr.oninput = () => { state.max_rounds = parseInt(mr.value || '20'); };
      const pj = main.querySelector('#proj'); if (pj) pj.onchange = () => { state.project_id = pj.value; };
      const tg = main.querySelector('#tags'); if (tg) tg.oninput = () => {
        state.tags = tg.value.split(/[,\s]+/).map(s => s.trim().toLowerCase()).filter(Boolean);
      };
      main.querySelector('#create').onclick = doCreate;
    }

    async function doCreate() {
      if (!state.template_id) { toast('请先选模板', 'error'); return; }
      if (!state.provider_id) { toast('请选 Provider', 'error'); return; }
      if (!state.model_id) { toast('请选 Model', 'error'); return; }
      // vars 注入 sandbox 作为默认
      state.vars.sandbox = state.sandbox;
      try {
        const res = await xchat.sessions.create({
          template_id: state.template_id,
          vars: state.vars,
          provider_id: state.provider_id,
          model_id: state.model_id,
          sandbox: state.sandbox,
          max_rounds: state.max_rounds,
          project_id: state.project_id || undefined,
          tags: state.tags,
        });
        Router.go('#/chat/' + res.id);
      } catch (e) {
        toast('创建失败: ' + ((e && (e.error || e.message)) || JSON.stringify(e)), 'error');
      }
    }

    render();
  });

  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
  function toast(msg, type) {
    const t = document.createElement('div');
    t.className = 'toast ' + (type || '');
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(() => document.body.removeChild(t), 2500);
  }
})();
