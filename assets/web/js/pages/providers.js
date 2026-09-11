// Providers 配置页:列表 + 编辑 modal(provider + models 表) + 测试连接
(function () {
  Router.on('#/providers', async function (main) {
    await renderList(main);
  });

  async function renderList(main) {
    const list = await xchat.providers.list();
    main.innerHTML = `
      <div class="row" style="margin-bottom:8px">
        <strong>Providers</strong>
        <span class="muted">LLM 接入配置 + 模型清单</span>
        <div class="grow"></div>
        <button class="btn primary" id="new">+ 新建 Provider</button>
      </div>
      <div id="list" class="card"></div>
    `;
    main.querySelector('#new').onclick = () => editProvider(main, null);
    const box = main.querySelector('#list');
    if (!list.length) {
      box.innerHTML = '<div class="muted" style="padding:20px;text-align:center">无 provider。点 "+ 新建 Provider" 开始。</div>';
      return;
    }
    box.innerHTML = list.map(p => `
      <div class="list-item" data-id="${esc(p.id)}">
        <div class="row">
          <strong>${esc(p.id)}</strong>
          <span class="kbd">${esc(p.type)}</span>
          <span class="muted">${esc(p.base_url)}</span>
          <span class="muted">· ${p.models.length} 模型</span>
          <span class="grow"></span>
          <button class="btn" data-act="test">测试连接</button>
          <button class="btn" data-act="edit">编辑</button>
          <button class="btn danger" data-act="delete">删除</button>
        </div>
        <div class="muted" style="margin-top:4px">
          ${p.models.slice(0, 5).map(m => esc(m.id)).join(', ')}${p.models.length > 5 ? ' …' : ''}
        </div>
      </div>
    `).join('');
    box.querySelectorAll('.list-item').forEach(el => {
      const id = el.dataset.id;
      const cur = list.find(x => x.id === id);
      el.querySelectorAll('button').forEach(btn => {
        btn.onclick = async () => {
          if (btn.dataset.act === 'edit') return editProvider(main, id);
          if (btn.dataset.act === 'delete') {
            const ok = await Modal.confirm({
              title: '删除 Provider',
              message: '删除 provider ' + id + ' ?现有会话对该 provider 的引用将无法工作。',
              confirmText: '删除', danger: true,
            });
            if (!ok) return;
            await xchat.providers.delete(id);
            await renderList(main);
          }
          if (btn.dataset.act === 'test') {
            btn.disabled = true;
            const oldText = btn.textContent;
            btn.textContent = '测试中…';
            try {
              const res = await xchat.providers.test(id);
              if (res.ok) {
                toast(`${id}: OK ${res.latency_ms}ms`, 'ok');
              } else {
                toast(`${id}: 失败 ${res.error || ''} ${res.latency_ms ? res.latency_ms + 'ms' : ''}`, 'error');
              }
            } catch (e) {
              toast('测试异常: ' + (e && (e.error || e.message) || JSON.stringify(e)), 'error');
            } finally {
              btn.disabled = false;
              btn.textContent = oldText;
            }
          }
        };
      });
    });
  }

  async function editProvider(main, id) {
    let cur;
    if (id) {
      cur = await xchat.providers.get(id);
      if (!cur) { main.innerHTML = '<div class="muted">未找到</div>'; return; }
    } else {
      cur = { id: '', type: 'openai_compatible', base_url: '', api_key: '', models: [] };
    }

    main.innerHTML = `
      <div class="row" style="margin-bottom:8px">
        <button class="btn" id="back">← 返回</button>
        <strong>${id ? '编辑' : '新建'} Provider</strong>
      </div>
      <div class="card">
        <div class="field"><label>ID (唯一标识)</label>
          <input id="pid" value="${esc(cur.id)}" ${id ? 'readonly' : ''} placeholder="openai-main / anthropic-main / ollama-local">
        </div>
        <div class="field"><label>类型</label>
          <select id="ptype">
            <option value="openai_compatible" ${cur.type === 'openai_compatible' ? 'selected' : ''}>openai_compatible (OpenAI / Ollama / 其它 /v1/chat/completions)</option>
            <option value="anthropic" ${cur.type === 'anthropic' ? 'selected' : ''}>anthropic (Messages API)</option>
          </select>
        </div>
        <div class="field"><label>Base URL</label>
          <input id="purl" value="${esc(cur.base_url)}" placeholder="https://api.openai.com/v1 或 http://localhost:11434/v1">
        </div>
        <div class="field"><label>API Key <span class="muted">(本地保存,纯文本)</span></label>
          <div class="row">
            <input id="pkey" type="password" value="${esc(cur.api_key)}" placeholder="sk-..." style="flex:1">
            <button class="btn" id="showkey">显示</button>
          </div>
        </div>

        <div class="row" style="margin:12px 0 6px">
          <strong>模型</strong>
          <span class="muted">上下文窗口单位 tokens;价格单位 CNY / 1M tokens(用于成本面板)</span>
          <span class="grow"></span>
          <button class="btn" id="addm">+ 添加模型</button>
        </div>
        <div id="models" class="model-list"></div>
      </div>

      <div class="row" style="margin-top:12px;justify-content:flex-end;gap:6px">
        <button class="btn" id="test">测试连接</button>
        <button class="btn" id="test2">用首个模型测试</button>
        <button class="btn primary" id="save">保存</button>
      </div>
    `;
    main.querySelector('#back').onclick = () => renderList(main);

    // 显示/隐藏 key
    main.querySelector('#showkey').onclick = () => {
      const inp = main.querySelector('#pkey');
      inp.type = inp.type === 'password' ? 'text' : 'password';
      main.querySelector('#showkey').textContent = inp.type === 'password' ? '显示' : '隐藏';
    };

    // 模型表
    const modelsBox = main.querySelector('#models');
    // 拉一次当前汇率,用于后面"显示用的 CNY 价格"。
    // 价格存储约定是 CNY/1M tokens(成本面板直接按 CNY 算再换显示币种),
    // 所以这里不需要做 USD↔CNY 换算,直接显示 cur 里已经存好的值。
    let _cnyRate = 7.25;
    try {
      const cfg0 = await xchat.config.get();
      const r0 = cfg0 && cfg0.ui && cfg0.ui.fx_rates;
      if (r0 && typeof r0.CNY === 'number' && r0.CNY > 0) _cnyRate = r0.CNY;
    } catch (_) {}
    function opt(value, label, current) {
      const cur = (current == null) ? '--' : String(current);
      const sel = (value === cur) ? ' selected' : '';
      return `<option value="${value}"${sel}>${label}</option>`;
    }
    function drawModels() {
      modelsBox.innerHTML = (cur.models || []).map((m, i) => `
        <div class="model-row" data-idx="${i}">
          <div class="model-row-id">
            <label class="field-label" for="mid-${i}">模型 ID</label>
            <input id="mid-${i}" data-f="id" value="${esc(m.id)}" placeholder="model-id">
          </div>
          <div class="model-row-params">
            <div class="num-cell">
              <label class="field-label" for="mctx-${i}">上下文窗口 <span class="muted">(tokens)</span></label>
              <input id="mctx-${i}" data-f="context" type="number" min="0" value="${m.context || 0}" placeholder="例如 128000">
            </div>
            <div class="num-cell">
              <label class="field-label" for="min-${i}">输入价格 <span class="muted">(CNY/1M tok)</span></label>
              <input id="min-${i}" data-f="in" type="number" min="0" step="0.01" value="${m.pricing && m.pricing.in || 0}" placeholder="18">
            </div>
            <div class="num-cell">
              <label class="field-label" for="mout-${i}">输出价格 <span class="muted">(CNY/1M tok)</span></label>
              <input id="mout-${i}" data-f="out" type="number" min="0" step="0.01" value="${m.pricing && m.pricing.out || 0}" placeholder="72">
            </div>
            <div class="num-cell">
              <label class="field-label" for="mcache-${i}">缓存价格 <span class="muted">(CNY/1M tok)</span></label>
              <input id="mcache-${i}" data-f="cache" type="number" min="0" step="0.01" value="${m.pricing && m.pricing.cache || 0}" placeholder="9">
            </div>
            <div class="num-cell">
              <label class="field-label" for="mthink-${i}">thinking</label>
              <select id="mthink-${i}" data-f="thinking">
                ${opt('--', '不传入该参数', m.thinking)}
                ${opt('enabled', 'enabled', m.thinking)}
                ${opt('disabled', 'disabled', m.thinking)}
                ${opt('adaptive', 'adaptive', m.thinking)}
              </select>
            </div>
            <div class="num-cell">
              <label class="field-label" for="mreason-${i}">reasoning_effort</label>
              <select id="mreason-${i}" data-f="reasoning_effort">
                ${opt('--', '不传入该参数', m.reasoning_effort)}
                ${opt('max', 'max', m.reasoning_effort)}
                ${opt('xhigh', 'xhigh', m.reasoning_effort)}
                ${opt('high', 'high', m.reasoning_effort)}
                ${opt('medium', 'medium', m.reasoning_effort)}
                ${opt('low', 'low', m.reasoning_effort)}
                ${opt('minimal', 'minimal', m.reasoning_effort)}
                ${opt('none', 'none', m.reasoning_effort)}
              </select>
            </div>
            <div class="num-cell">
              <label class="field-label" for="mtemp-${i}">temperature <span class="muted">(0.0 ~ 2.0,留空=不传)</span></label>
              <input id="mtemp-${i}" data-f="temperature" type="number" min="0" max="2" step="0.05" value="${m.temperature == null ? '' : m.temperature}" placeholder="如 1.0">
            </div>
          </div>
          <div class="model-row-actions">
            <button class="btn" data-act="testm" title="测试此模型">测</button>
            <button class="btn danger" data-act="del" title="删除此模型">删</button>
          </div>
        </div>
      `).join('');
      modelsBox.querySelectorAll('[data-idx]').forEach(row => {
        const idx = parseInt(row.dataset.idx);
        // input/select 变化 → 回写 cur
        row.querySelectorAll('input,select').forEach(el => {
          const handler = () => {
            const f = el.dataset.f;
            const m = cur.models[idx];
            if (f === 'id') m.id = el.value;
            else if (f === 'context') m.context = parseInt(el.value || '0');
            else if (f === 'thinking' || f === 'reasoning_effort') {
              // '--' 表示不传入该参数(后端以此判断)
              m[f] = (el.value === '--' || !el.value) ? null : el.value;
            } else if (f === 'temperature') {
              if (el.value === '' || el.value == null) m.temperature = null;
              else {
                let v = parseFloat(el.value);
                if (isNaN(v)) v = null; else v = Math.max(0, Math.min(2, v));
                m.temperature = v;
              }
            } else {
              m.pricing = m.pricing || { in: 0, out: 0, cache: 0 };
              m.pricing[f] = parseFloat(el.value || '0');
            }
          };
          if (el.tagName === 'SELECT') el.onchange = handler; else el.oninput = handler;
        });
        row.querySelector('[data-act="del"]').onclick = () => {
          cur.models.splice(idx, 1);
          drawModels();
        };
        row.querySelector('[data-act="testm"]').onclick = async () => {
          const m = cur.models[idx];
          if (!m.id) { toast('先填 model id', 'error'); return; }
          // 先 save 再 test
          await saveQuiet();
          const res = await xchat.providers.test(cur.id, m.id);
          if (res.ok) toast(`${m.id}: OK ${res.latency_ms}ms`, 'ok');
          else toast(`${m.id}: 失败 ${res.error || ''}`, 'error');
        };
      });
    }
    drawModels();

    main.querySelector('#addm').onclick = () => {
      cur.models.push({ id: '', context: 0, pricing: { in: 0, out: 0, cache: 0 },
        thinking: null, reasoning_effort: null, temperature: null });
      drawModels();
    };

    main.querySelector('#save').onclick = async () => {
      cur.id = main.querySelector('#pid').value.trim();
      cur.type = main.querySelector('#ptype').value;
      cur.base_url = main.querySelector('#purl').value.trim();
      cur.api_key = main.querySelector('#pkey').value;
      if (!cur.id) { toast('ID 必填', 'error'); return; }
      // 清空空 id 模型
      cur.models = cur.models.filter(m => m.id && m.id.trim());
      try {
        await xchat.providers.upsert(cur);
        toast('已保存 ' + cur.id, 'ok');
        await renderList(main);
      } catch (e) {
        toast('保存失败: ' + (e && (e.error || e.message) || JSON.stringify(e)), 'error');
      }
    };

    async function saveQuiet() {
      cur.id = main.querySelector('#pid').value.trim();
      cur.type = main.querySelector('#ptype').value;
      cur.base_url = main.querySelector('#purl').value.trim();
      cur.api_key = main.querySelector('#pkey').value;
      cur.models = cur.models.filter(m => m.id && m.id.trim());
      if (!cur.id) throw new Error('id required');
      await xchat.providers.upsert(cur);
    }

    main.querySelector('#test').onclick = async () => {
      try {
        await saveQuiet();
        const res = await xchat.providers.test(cur.id);
        if (res.ok) toast('OK ' + res.latency_ms + 'ms', 'ok');
        else toast('失败 ' + (res.error || ''), 'error');
      } catch (e) {
        toast('测试异常: ' + e.message, 'error');
      }
    };
    main.querySelector('#test2').onclick = async () => {
      try {
        await saveQuiet();
        const mid = cur.models.length ? cur.models[0].id : null;
        const res = await xchat.providers.test(cur.id, mid);
        if (res.ok) toast('OK ' + res.latency_ms + 'ms (' + (mid || 'no model') + ')', 'ok');
        else toast('失败 ' + (res.error || ''), 'error');
      } catch (e) {
        toast('测试异常: ' + e.message, 'error');
      }
    };
  }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function toast(msg, type) {
    const t = document.createElement('div');
    t.className = 'toast ' + (type || '');
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(() => document.body.removeChild(t), 2500);
  }
})();
