(function () {
  Router.on(/^#\/chat\/(.+)$/, async function (main, match) {
    const sessionId = match[1];
    let session;
    try { session = await xchat.sessions.get(sessionId); }
    catch (e) { main.innerHTML = '<div class="muted">会话不存在</div>'; return; }

    // 对话页面采用 flex-column 三段式:
    //   chat-header (sticky top) —— 会话信息栏始终可见,跟随窗口滚动但不滚走
    //   chat-msgs  (flex:1, overflow-y:auto) —— 消息区独立滚动
    //   toolbar    (sticky bottom) —— 输入框始终贴底
    // 这样用户在长会话里滚消息不会丢失标题/项目/sandbox/累计 usage/操作按钮。
    main.innerHTML = `
      <div class="chat-page">
        <div class="chat-header row">
          <a href="#/sessions" class="btn">← 返回</a>
          <strong id="title">${esc(session.title || sessionId.substring(0, 8))}</strong>
          <span id="projchip"></span>
          <span id="tagchips"></span>
          <span class="muted">${esc(session.sandbox)}</span>
          <span class="muted" id="usage"></span>
          <div class="grow"></div>
          <button class="btn" id="resend">编辑重发</button>
          <button class="btn" id="editor">编辑器</button>
        </div>
        <div id="msgs" class="chat-msgs card"></div>
        <div class="toolbar chat-toolbar">
          <textarea id="input" placeholder="输入消息... (Enter 发送 / Ctrl+Enter 换行)"></textarea>
          <button class="btn primary" id="send">发送</button>
          <button class="btn" id="stop">停止</button>
        </div>
      </div>
    `;
    renderChips(session);
    renderMessages(session);
    const input = main.querySelector('#input');
    main.querySelector('#send').onclick = () => doSend();
    input.addEventListener('keydown', (e) => {
      // Enter 发送;Ctrl+Enter(或 Cmd+Enter on mac)换行
      if (e.key === 'Enter' && !e.ctrlKey && !e.metaKey) {
        e.preventDefault();
        doSend();
      } else if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        // 浏览器默认会在 textarea 中插入换行,这里显式不阻止,
        // 行为更直观(Ctrl+Enter = 插入换行符,Enter = 发送)。
      }
    });
    main.querySelector('#stop').onclick = () => xchat.chat.stop(sessionId);
    main.querySelector('#editor').onclick = () => xchat.sessions.openInEditor(sessionId);
    main.querySelector('#resend').onclick = () => doResend();

    function renderMessages(s) {
      const box = main.querySelector('#msgs');
      box.innerHTML = s.messages.map((m) => renderMsg(m)).join('');
      box.scrollTop = box.scrollHeight;
      // 顶部累计 usage:补齐 cache 字段(原版只显示 ctx/in/out,看不到 cache 用量)
      main.querySelector('#usage').textContent =
        `ctx:${s.sys_context} in:${s.sys_input} out:${s.sys_output} cache:${s.sys_cache}`;
    }
    async function renderChips(s) {
      const projEl = main.querySelector('#projchip');
      const tagEl = main.querySelector('#tagchips');
      const proj = s.project_id ? (await xchat.projects.list()).find((p) => p.id === s.project_id) : null;
      projEl.innerHTML = proj
        ? `<span class="dot" style="background:${esc(proj.color)}"></span><span class="muted">${esc(proj.name)}</span>`
        : '';
      tagEl.innerHTML = (s.tags || []).map((t) => `<span class="kbd">#${esc(t)}</span>`).join(' ');
    }
    function renderMsg(m) {
      // user / assistant / tool / system 一律走 markdown 渲染,这样用户也能用表格/代码块/数学等
      const body = Markdown.render(m.text || '');
      // 单条消息的 token 元数据:补齐 cache 字段(原版只显示 in/out)
      const meta = m.role === 'assistant'
        ? `<div class="muted">in:${m.input} out:${m.output} cache:${m.cache || 0}${m.model ? ` · ${esc(m.model)}` : ''}</div>`
        : '';
      const tcHtml = (m.tool_calls && m.tool_calls.length)
        ? m.tool_calls.map((c) => renderToolCall(c)).join('')
        : '';
      const streamingAttr = m.__streaming ? ' data-streaming="1"' : '';
      return `<div class="msg ${m.role}"${streamingAttr}><div class="msg-body">${body}</div>${meta}</div>${tcHtml}`;
    }

    // 单个 tool_call 默认展示前 5 行,其余用 ... 省略;点开可看完整内容。
    function renderToolCall(c) {
      const argText = String(c.arguments || '');
      const lines = argText.split('\n');
      const limit = 5;
      const head = lines.slice(0, limit).join('\n');
      const more = lines.length > limit;
      const preview = esc(head) + (more ? '\n...' : '');
      if (!more) {
        return `<div class="msg system"><div class="muted">[tool] ${esc(c.name)}</div><pre class="tc-pre">${preview}</pre></div>`;
      }
      return `<div class="msg system"><details><summary class="muted">[tool] ${esc(c.name)} (共 ${lines.length} 行,已折叠)</summary><pre class="tc-pre">${esc(argText)}</pre></details></div>`;
    }

    function appendMessage(msg) {
      // 通用:把消息加到数据,DOM 也加一条新节点。
      session.messages.push(msg);
      const box = main.querySelector('#msgs');
      box.insertAdjacentHTML('beforeend', renderMsg(msg));
      box.scrollTop = box.scrollHeight;
    }

    function appendChunk(delta) {
      // 流式 chunk:必须只更新一条 assistant 节点,绝不重复插入。
      const box = main.querySelector('#msgs');
      let last = session.messages[session.messages.length - 1];
      if (!last || last.role !== 'assistant' || !last.__streaming) {
        last = { role: 'assistant', text: delta, tool_calls: [], input: 0, output: 0, __streaming: true };
        session.messages.push(last);
        box.insertAdjacentHTML('beforeend', renderMsg(last));
      } else {
        last.text = (last.text || '') + delta;
        const streamingEl = box.querySelector('.msg.assistant[data-streaming="1"]');
        if (streamingEl) {
          const bodyEl = streamingEl.querySelector('.msg-body');
          if (bodyEl) bodyEl.innerHTML = Markdown.render(last.text);
        }
      }
      box.scrollTop = box.scrollHeight;
    }

    function finalizeAssistant(text, toolCalls, usage) {
      // 收到 assistant_done:从数据里找到最后一条 streaming assistant,合并终态并重渲。
      // 修复:原版只用 `last.input || 0`,但 streaming 节点原本就是 0,
      // 导致前端永远显示 0,必须关闭重开会话才能看到真实 in/out/cache。
      // 现在事件里带 usage(input/output/cache),直接覆盖到 streaming 节点上,
      // 渲染时即可看到本轮用量,无需等落盘回读。
      const last = session.messages[session.messages.length - 1];
      if (last && last.role === 'assistant') {
        if (typeof text === 'string') last.text = text;
        if (Array.isArray(toolCalls)) last.tool_calls = toolCalls;
        if (usage) {
          last.input = usage.input || 0;
          last.output = usage.output || 0;
          last.cache = usage.cache || 0;
        } else {
          last.input = last.input || 0;
          last.output = last.output || 0;
          last.cache = last.cache || 0;
        }
        delete last.__streaming;
      }
      renderMessages(session);
    }

    // 状态:对话是否仍在进行。
    // 进入运行:发送按钮显示运动图标(spinner);输入框禁用。
    // 结束:发送按钮恢复"发送";输入框恢复。
    let isRunning = false;
    const sendBtn = main.querySelector('#send');
    function setRunning(on) {
      if (on === isRunning) return;
      isRunning = on;
      if (on) {
        sendBtn.classList.add('sending');
        sendBtn.innerHTML = '<span class="spinner"></span>';
        sendBtn.disabled = true;
        input.disabled = true;
        input.placeholder = '对话进行中,请等待结束…';
      } else {
        sendBtn.classList.remove('sending');
        sendBtn.textContent = '发送';
        sendBtn.disabled = false;
        input.disabled = false;
        input.placeholder = '输入消息... (Enter 发送 / Ctrl+Enter 换行)';
      }
    }

    // 事件订阅
    xchat.events.on('chunk', (e) => {
      if (e.sessionId !== sessionId) return;
      setRunning(true);
      appendChunk(e.delta);
    });
    // user_appendered 由后端发出,前端只信任这一份,doSend 不再预加。
    xchat.events.on('user_appended', (e) => {
      if (e.sessionId !== sessionId) return;
      setRunning(true);
      // 防止后端把同一条 user 重复推过来时再加一份
      const last = session.messages[session.messages.length - 1];
      if (last && last.role === 'user' && last.text === e.text) return;
      appendMessage({ role: 'user', text: e.text, tool_calls: [] });
    });
    xchat.events.on('assistant_done', (e) => {
      if (e.sessionId !== sessionId) return;
      finalizeAssistant(e.text, e.tool_calls, {
        input: e.input,
        output: e.output,
        cache: e.cache,
      });
    });
    xchat.events.on('tool_start', (e) => {
      if (e.sessionId !== sessionId) return;
      setRunning(true);
      toast('工具开始: ' + e.name, 'warn');
    });
    xchat.events.on('tool_done', (e) => {
      if (e.sessionId !== sessionId) return;
      appendMessage({ role: 'tool', text: e.result || '', tool_call_id: e.callId, tool_name: e.name, tool_calls: [] });
    });
    xchat.events.on('done', (e) => {
      if (e.sessionId !== sessionId) return;
      setRunning(false);
      toast('完成', 'ok');
    });
    xchat.events.on('blocked_layer_a', (e) => {
      if (e.sessionId !== sessionId) return;
      setRunning(false);
      toast('Layer A 拦截:' + e.message, 'error');
    });
    xchat.events.on('compressed', (e) => { if (e.sessionId === sessionId) toast('已压缩 ' + e.archivedCount + ' 条历史', 'warn'); });
    xchat.events.on('blocked_exception_yolo', (e) => {
      if (e.sessionId !== sessionId) return;
      setRunning(false);
      toast('Layer B 例外(yolo 拒绝):' + e.message, 'error');
    });
    xchat.events.on('error', (e) => {
      if (e.sessionId !== sessionId) return;
      setRunning(false);
      toast('错误: ' + e.message, 'error');
    });
    xchat.events.on('confirm_required', (e) => { if (e.sessionId === sessionId) showConfirm(e); });
    xchat.events.on('session_continued', (e) => {
      if (e.oldId === sessionId) { toast('已续接到新会话', 'warn'); Router.go('#/chat/' + e.newId); }
    });
    xchat.events.on('stopped', (e) => {
      if (e.sessionId !== sessionId) return;
      setRunning(false);
      toast('已停止', 'warn');
    });

    async function doSend() {
      const t = input.value.trim();
      if (!t) return;
      input.value = '';
      // 不再前端预加 user;后端会通过 user_appended 事件回推一条。
      // 兜底:5s 后若仍没有匹配文本的 user 出现在 session.messages 中,
      // 才降级补一条(避免因流式 assistant 抢先占据 messages 末尾导致误判)。
      await xchat.chat.send(sessionId, t);
      setTimeout(() => {
        const has = session.messages.some((m) => m.role === 'user' && m.text === t);
        if (!has) appendMessage({ role: 'user', text: t, tool_calls: [] });
      }, 5000);
    }
    async function doResend() {
      const last = [...session.messages].reverse().find((m) => m.role === 'user');
      const t = await Modal.prompt({
        title: '编辑重发',
        message: '修改最后一条 user 消息后重新发送,后续消息将被截断。',
        label: '消息内容',
        value: last ? last.text : '',
        multiline: true,
      });
      if (t === null) return;
      session = await xchat.sessions.resend(sessionId, t);
      renderMessages(session);
      await xchat.chat.send(sessionId, t);
    }

    function showConfirm(e) {
      const bg = document.createElement('div'); bg.className = 'modal-bg';
      bg.innerHTML = `<div class="modal">
        <h3>需要确认:${esc(e.name)}</h3>
        <div class="muted" style="margin-bottom:8px">参数: <code>${esc(JSON.stringify(e.arguments))}</code></div>
        ${e.exceptionMatch ? '<div class="muted" style="color:var(--warn)">该命令在 Layer B 例外列表中</div>' : ''}
        <div class="row" style="margin-top:12px;justify-content:flex-end">
          <button class="btn" id="deny">拒绝</button>
          <button class="btn" id="allow-once">允许本次</button>
          <button class="btn primary" id="allow-session">本次会话不再询问</button>
        </div>
      </div>`;
      document.body.appendChild(bg);
      bg.querySelector('#deny').onclick = () => { xchat.chat.confirmTool(sessionId, e.callId, { allow: false }); document.body.removeChild(bg); };
      bg.querySelector('#allow-once').onclick = () => { xchat.chat.confirmTool(sessionId, e.callId, { allow: true }); document.body.removeChild(bg); };
      bg.querySelector('#allow-session').onclick = () => { xchat.chat.confirmTool(sessionId, e.callId, { allow: true, remember: true }); document.body.removeChild(bg); };
    }
  });
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function toast(msg, type) {
    const t = document.createElement('div'); t.className = 'toast ' + (type || ''); t.textContent = msg;
    document.body.appendChild(t); setTimeout(() => document.body.removeChild(t), 3000);
  }
})();
