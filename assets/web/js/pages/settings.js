// 设置页:主题切换(浅色/深色/跟随系统) + 确认模式(yolo/normal/safe) + 外部编辑器命令
(function () {
  Router.on('#/settings', async function (main) {
    await render(main);
  });

  async function render(main) {
    const cfg = await xchat.config.get();
    const curTheme = (window.XchatTheme && XchatTheme.currentMode()) || 'system';
    const curConfirm = (cfg.ui && cfg.ui.confirm_mode) || 'normal';
    const curEditor = (cfg.ui && cfg.ui.editor) || '';
    const resolvedPreview = resolveEditorPreview(curEditor);

    main.innerHTML = `
      <div class="row" style="margin-bottom:12px">
        <strong>设置</strong>
      </div>

      <div class="card" style="margin-bottom:12px">
        <h3 style="margin:0 0 8px">UI 主题</h3>
        <div class="muted" style="margin-bottom:8px">切换整体配色,也可跟随系统。</div>
        <div class="row" id="themeBtns" style="gap:6px">
          ${themeBtn('light', '浅色', curTheme)}
          ${themeBtn('dark', '深色', curTheme)}
          ${themeBtn('system', '跟随系统', curTheme)}
        </div>
      </div>

      <div class="card" style="margin-bottom:12px">
        <h3 style="margin:0 0 8px">工具确认模式</h3>
        <div class="muted" style="margin-bottom:8px">yolo = 不弹窗直接执行;normal = 危险工具弹窗;safe = 所有工具都弹窗。</div>
        <div class="row" id="confirmBtns" style="gap:6px">
          ${confirmBtn('safe', 'safe', curConfirm)}
          ${confirmBtn('normal', 'normal', curConfirm)}
          ${confirmBtn('yolo', 'yolo', curConfirm)}
        </div>
      </div>

      <div class="card">
        <h3 style="margin:0 0 8px">外部编辑器命令</h3>
        <div class="muted" style="margin-bottom:8px">
          用于"在编辑器中打开 xml"。留空时回退到 <code>$EDITOR</code> 环境变量,再回退到 <code>vi</code>。
          支持空格 / 引号包裹的多段命令;命令中含 <code>{}</code> 占位时会被替换为文件路径,否则路径追加到末尾。
        </div>
        <div class="field">
          <input id="editorCmd" value="${esc(curEditor)}"
                 placeholder="例如: code   |   code --reuse-window   |   code --goto {}">
        </div>
        <div class="row" style="gap:8px;margin-top:8px">
          <button class="btn primary" id="editorSaveBtn">保存</button>
          <button class="btn" id="editorClearBtn">清除(回退到 \$EDITOR / vi)</button>
        </div>
        <div class="muted" style="margin-top:8px" id="editorResolved">
          当前生效: <code>${esc(resolvedPreview)}</code>
        </div>
      </div>
    `;

    main.querySelectorAll('#themeBtns [data-theme]').forEach(b => {
      b.onclick = async () => {
        const m = b.dataset.theme;
        if (window.XchatTheme) await XchatTheme.setMode(m);
        await render(main);
      };
    });
    main.querySelectorAll('#confirmBtns [data-confirm]').forEach(b => {
      b.onclick = async () => {
        const m = b.dataset.confirm;
        try {
          await xchat.config.set({ ui: { confirm_mode: m } });
          toast('确认模式已切换为 ' + m, 'ok');
          await render(main);
        } catch (e) {
          toast('切换失败: ' + (e && (e.error || e.message) || JSON.stringify(e)), 'error');
        }
      };
    });

    const editorSaveBtn = main.querySelector('#editorSaveBtn');
    const editorClearBtn = main.querySelector('#editorClearBtn');
    const editorInput = main.querySelector('#editorCmd');
    editorInput.addEventListener('input', () => updateResolvedPreview(main, editorInput.value));
    editorSaveBtn.onclick = async () => {
      const raw = (editorInput.value || '').trim();
      try {
        await xchat.config.set({ ui: { editor: raw === '' ? null : raw } });
        toast(raw === '' ? '已清除,回退到 $EDITOR / vi' : '已保存: ' + raw, 'ok');
        await render(main);
      } catch (e) {
        toast('保存失败: ' + (e && (e.error || e.message) || JSON.stringify(e)), 'error');
      }
    };
    editorClearBtn.onclick = async () => {
      try {
        await xchat.config.set({ ui: { editor: null } });
        toast('已清除,回退到 $EDITOR / vi', 'ok');
        await render(main);
      } catch (e) {
        toast('清除失败: ' + (e && (e.error || e.message) || JSON.stringify(e)), 'error');
      }
    };
  }

  // 与 Dart 侧 _resolveEditor 对齐:ui.editor > $EDITOR(JS 这里读不到,显示 "(env)") > vi
  // 仅用于在 UI 上预览当前命令 + 一个示例路径,真正生效的是 Dart 端。
  function resolveEditorPreview(uiEditor) {
    if (uiEditor && uiEditor.trim()) return uiEditor.trim();
    return '(回退 $EDITOR / vi)';
  }

  // 把命令 + 一个示例路径拼成预览,{} 替换,否则追加。
  function buildPreview(cmd) {
    const samplePath = '/path/to/<id>.xml';
    const tokens = tokenize(cmd);
    if (tokens.length === 0) return '(回退 $EDITOR / vi)';
    const exe = tokens[0];
    const rest = tokens.slice(1);
    if (rest.some(t => t.indexOf('{}') >= 0)) {
      return exe + ' ' + rest.map(t => t.split('{}').join(samplePath)).join(' ');
    }
    return exe + (rest.length ? ' ' + rest.join(' ') + ' ' + samplePath : ' ' + samplePath);
  }

  function updateResolvedPreview(main, cmd) {
    const box = main.querySelector('#editorResolved');
    if (!box) return;
    const trimmed = (cmd || '').trim();
    if (!trimmed) {
      box.innerHTML = '当前生效: <code>(回退 $EDITOR / vi)</code>';
    } else {
      box.innerHTML = '预览: <code>' + esc(buildPreview(trimmed)) + '</code>';
    }
  }

  // 与 Dart 侧 _tokenizeCmd 对齐:空格分隔,支持双/单引号包裹。
  function tokenize(s) {
    const out = [];
    let buf = '';
    let quote = null;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (quote) {
        if (c === quote) quote = null;
        else buf += c;
      } else if (c === '"' || c === '\'') {
        quote = c;
      } else if (c === ' ' || c === '\t') {
        if (buf.length) { out.push(buf); buf = ''; }
      } else {
        buf += c;
      }
    }
    if (buf.length) out.push(buf);
    return out;
  }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function themeBtn(v, label, cur) {
    return `<button class="btn ${v === cur ? 'primary' : ''}" data-theme="${v}">${label}</button>`;
  }
  function confirmBtn(v, label, cur) {
    return `<button class="btn ${v === cur ? 'primary' : ''}" data-confirm="${v}">${label}</button>`;
  }
  function toast(msg, type) {
    const t = document.createElement('div');
    t.className = 'toast ' + (type || '');
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(() => document.body.removeChild(t), 2000);
  }
})();
