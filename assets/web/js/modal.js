// H5 弹窗统一封装:代替浏览器原生 confirm() / prompt(),避免 WebView 里阻塞或被屏蔽。
// 用法:
//   Modal.confirm({ title:'...', message:'...', confirmText:'删除', danger:true })
//     .then(ok => { if (ok) ... });
//   Modal.prompt({ title:'...', label:'名称', value:'', placeholder:'...' })
//     .then(v => v === null ? 用户点了取消 : 实际输入);
//   Modal.alert({ title:'...', message:'...' });   // 单按钮信息
//   Modal.view({ title:'...', body:'<pre>...</pre>' });  // 纯展示(查看 XML)
(function () {
  if (window.Modal) return;

  function el(tag, attrs, html) {
    const e = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      if (k === 'class') e.className = attrs[k];
      else if (k === 'style') e.style.cssText = attrs[k];
      else if (k.startsWith('on') && typeof attrs[k] === 'function') e.addEventListener(k.slice(2), attrs[k]);
      else e.setAttribute(k, attrs[k]);
    }
    if (html != null) e.innerHTML = html;
    return e;
  }

  function open(content) {
    const bg = el('div', { class: 'modal-bg', 'data-modal': '1' });
    const box = el('div', { class: 'modal' });
    box.appendChild(content);
    bg.appendChild(box);
    document.body.appendChild(bg);
    function close(v) {
      if (bg.parentNode) bg.parentNode.removeChild(bg);
      document.removeEventListener('keydown', onKey);
      resolve(v);
    }
    let resolve;
    const promise = new Promise(r => { resolve = r; });
    function onKey(e) {
      if (e.key === 'Escape') close(null);
      else if (e.key === 'Enter' && e.target.tagName !== 'TEXTAREA') {
        const ok = bg.querySelector('[data-modal-primary]');
        if (ok) ok.click();
      }
    }
    document.addEventListener('keydown', onKey);
    bg.addEventListener('click', e => { if (e.target === bg) close(null); });
    return { close, promise, box };
  }

  function confirm(opts) {
    opts = opts || {};
    const content = el('div');
    content.appendChild(el('h3', null, escHtml(opts.title || '确认')));
    if (opts.message) content.appendChild(el('div', { class: 'muted', style: 'margin-bottom:8px' }, escHtml(opts.message)));
    const row = el('div', { class: 'row', style: 'margin-top:12px;justify-content:flex-end;gap:6px' });
    const cancel = el('button', { class: 'btn', 'data-modal-cancel': '1' }, opts.cancelText || '取消');
    const ok = el('button', { class: 'btn ' + (opts.danger ? 'danger' : 'primary'), 'data-modal-primary': '1' }, opts.confirmText || '确定');
    row.appendChild(cancel); row.appendChild(ok);
    content.appendChild(row);
    // 修复:必须返回 open() 创建的真实 promise;之前误用 box._promise,
    // 那个槽位永不被赋值,confirm() 永远 hang(删除会话时"确认无反应"由此引起)。
    const { close, promise } = open(content);
    cancel.onclick = () => close(false);
    ok.onclick = () => close(true);
    setTimeout(() => ok.focus(), 0);
    return promise;
  }

  function color(opts) {
    // 色盘:16 个预设色 + 自定义 <input type="color">;选色变化即时预览。
    opts = opts || {};
    const preset = opts.presets || [
      '#4f7cff', '#6b8cff', '#2bb673', '#f5a623', '#e54848',
      '#9b59b6', '#1abc9c', '#e67e22', '#34495e', '#e91e63',
      '#16a085', '#d35400', '#7f8c8d', '#8e44ad', '#27ae60',
      '#2980b9',
    ];
    const initial = (opts.value && /^#[0-9a-fA-F]{6}$/.test(opts.value)) ? opts.value.toLowerCase() : '#4f7cff';
    let chosen = initial;

    const content = el('div');
    content.appendChild(el('h3', null, escHtml(opts.title || '选择颜色')));

    const grid = el('div', { class: 'color-grid' });
    preset.forEach(c => {
      const sw = el('button', { class: 'color-swatch' + (c === chosen ? ' sel' : ''), 'data-c': c, style: 'background:' + c, type: 'button' });
      sw.onclick = () => { chosen = c; sync(); };
      grid.appendChild(sw);
    });
    content.appendChild(grid);

    const customWrap = el('div', { class: 'row', style: 'gap:8px;align-items:center;margin-top:12px' });
    const customInput = el('input', { type: 'color', value: initial, style: 'width:48px;height:32px;padding:0;border:1px solid var(--border);border-radius:4px;cursor:pointer' });
    const customLabel = el('span', { class: 'muted' }, '自定义');
    customInput.addEventListener('input', () => { chosen = customInput.value; sync(); });
    customWrap.appendChild(customInput);
    customWrap.appendChild(customLabel);
    content.appendChild(customWrap);

    const preview = el('div', { style: 'margin-top:12px;padding:8px;border:1px solid var(--border);border-radius:4px;display:flex;align-items:center;gap:8px' });
    const previewDot = el('span', { class: 'dot', style: 'background:' + chosen });
    const previewTxt = el('code', null, chosen);
    preview.appendChild(previewDot);
    preview.appendChild(previewTxt);
    content.appendChild(preview);

    const row = el('div', { class: 'row', style: 'margin-top:12px;justify-content:flex-end;gap:6px' });
    const cancel = el('button', { class: 'btn' }, opts.cancelText || '取消');
    const ok = el('button', { class: 'btn primary', 'data-modal-primary': '1' }, opts.confirmText || '确定');
    row.appendChild(cancel); row.appendChild(ok);
    content.appendChild(row);

    const bg = el('div', { class: 'modal-bg', 'data-modal': '1' });
    const box = el('div', { class: 'modal' });
    box.appendChild(content);
    bg.appendChild(box);
    document.body.appendChild(bg);

    function sync() {
      previewDot.style.background = chosen;
      previewTxt.textContent = chosen;
      grid.querySelectorAll('.color-swatch').forEach(s => {
        if (s.dataset.c === chosen) s.classList.add('sel'); else s.classList.remove('sel');
      });
      if (/^#[0-9a-fA-F]{6}$/.test(chosen)) customInput.value = chosen;
    }

    let resolve;
    const promise = new Promise(r => { resolve = r; });
    function onKey(e) { if (e.key === 'Escape') finish(null); }
    document.addEventListener('keydown', onKey);
    bg.addEventListener('click', e => { if (e.target === bg) finish(null); });
    function finish(v) {
      if (bg.parentNode) bg.parentNode.removeChild(bg);
      document.removeEventListener('keydown', onKey);
      resolve(v);
    }
    cancel.onclick = () => finish(null);
    ok.onclick = () => finish(chosen);
    setTimeout(() => ok.focus(), 0);
    return promise;
  }

  function prompt(opts) {
    opts = opts || {};
    const content = el('div');
    content.appendChild(el('h3', null, escHtml(opts.title || '输入')));
    if (opts.message) content.appendChild(el('div', { class: 'muted', style: 'margin-bottom:8px' }, escHtml(opts.message)));
    const wrap = el('div', { class: 'field' });
    if (opts.label) wrap.appendChild(el('label', null, escHtml(opts.label)));
    const input = el(opts.multiline ? 'textarea' : 'input', {
      type: opts.multiline ? null : 'text',
      id: 'modal-input',
      value: opts.value == null ? '' : opts.value,
      placeholder: opts.placeholder || '',
      style: opts.multiline ? 'width:100%;min-height:120px;font-family:monospace;font-size:13px' : 'width:100%',
    });
    wrap.appendChild(input);
    content.appendChild(wrap);
    const row = el('div', { class: 'row', style: 'margin-top:12px;justify-content:flex-end;gap:6px' });
    const cancel = el('button', { class: 'btn' }, opts.cancelText || '取消');
    const ok = el('button', { class: 'btn ' + (opts.danger ? 'danger' : 'primary'), 'data-modal-primary': '1' }, opts.confirmText || '确定');
    row.appendChild(cancel); row.appendChild(ok);
    content.appendChild(row);

    let resolve;
    const promise = new Promise(r => { resolve = r; });
    const bg = el('div', { class: 'modal-bg', 'data-modal': '1' });
    const box = el('div', { class: 'modal' });
    box.appendChild(content);
    bg.appendChild(box);
    document.body.appendChild(bg);

    function onKey(e) {
      if (e.key === 'Escape') finish(null);
      else if (e.key === 'Enter' && !opts.multiline && document.activeElement === input) finish(input.value);
    }
    document.addEventListener('keydown', onKey);
    bg.addEventListener('click', e => { if (e.target === bg) finish(null); });

    function finish(v) {
      if (bg.parentNode) bg.parentNode.removeChild(bg);
      document.removeEventListener('keydown', onKey);
      resolve(v);
    }
    cancel.onclick = () => finish(null);
    ok.onclick = () => finish(opts.multiline ? input.value : input.value);

    // 如果是 select 模式(opts.choices 是数组),替换 input 为 select
    if (Array.isArray(opts.choices)) {
      const sel = el('select', { id: 'modal-input' });
      sel.style.width = '100%';
      if (opts.allowEmpty !== false) {
        const o0 = el('option', { value: '' }, opts.emptyLabel || '(无)');
        sel.appendChild(o0);
      }
      opts.choices.forEach(c => {
        const o = el('option', { value: typeof c === 'object' ? c.value : c },
          typeof c === 'object' ? c.label : c);
        sel.appendChild(o);
      });
      sel.value = opts.value == null ? '' : String(opts.value);
      input.parentNode.replaceChild(sel, input);
      setTimeout(() => sel.focus(), 0);
      ok.onclick = () => finish(sel.value);
    } else {
      setTimeout(() => { input.focus(); input.select && input.select(); }, 0);
    }
    return promise;
  }

  function alert(opts) {
    opts = opts || {};
    return prompt(Object.assign({}, opts, {
      label: null, placeholder: '', value: '', choices: null,
      confirmText: opts.confirmText || '好',
      multiline: false,
    }));
  }

  function view(opts) {
    // 只读展示大段文本(查看 XML)。返回 Promise,用户关掉时 resolve(null)。
    opts = opts || {};
    const content = el('div');
    content.appendChild(el('h3', null, escHtml(opts.title || '查看')));
    if (opts.message) content.appendChild(el('div', { class: 'muted', style: 'margin-bottom:8px' }, escHtml(opts.message)));
    const pre = el('pre', {
      style: 'max-height:60vh;overflow:auto;background:var(--card);color:var(--fg);padding:12px;border-radius:4px;font-size:12px;white-space:pre-wrap;word-break:break-all;margin:0',
    });
    pre.textContent = opts.body == null ? '' : String(opts.body);
    content.appendChild(pre);
    const row = el('div', { class: 'row', style: 'margin-top:12px;justify-content:flex-end;gap:6px' });
    const copyBtn = el('button', { class: 'btn' }, '复制');
    const closeBtn = el('button', { class: 'btn primary', 'data-modal-primary': '1' }, '关闭');
    row.appendChild(copyBtn); row.appendChild(closeBtn);
    content.appendChild(row);

    let resolve;
    const promise = new Promise(r => { resolve = r; });
    const bg = el('div', { class: 'modal-bg', 'data-modal': '1' });
    const box = el('div', { class: 'modal', style: 'max-width:780px;width:90%' });
    box.appendChild(content);
    bg.appendChild(box);
    document.body.appendChild(bg);

    function finish(v) {
      if (bg.parentNode) bg.parentNode.removeChild(bg);
      document.removeEventListener('keydown', onKey);
      resolve(v);
    }
    function onKey(e) { if (e.key === 'Escape') finish(null); }
    document.addEventListener('keydown', onKey);
    bg.addEventListener('click', e => { if (e.target === bg) finish(null); });
    closeBtn.onclick = () => finish(null);
    copyBtn.onclick = () => {
      const txt = pre.textContent;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(txt).then(
          () => { copyBtn.textContent = '已复制'; setTimeout(() => copyBtn.textContent = '复制', 1500); },
          () => fallback()
        );
      } else fallback();
      function fallback() {
        const ta = document.createElement('textarea');
        ta.value = txt; document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); copyBtn.textContent = '已复制'; setTimeout(() => copyBtn.textContent = '复制', 1500); }
        catch (e) {}
        document.body.removeChild(ta);
      }
    };
    return promise;
  }

  function escHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  window.Modal = { confirm, prompt, alert, view, color };
})();
