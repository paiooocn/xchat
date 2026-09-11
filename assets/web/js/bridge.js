// bridge.js: 在所有页面 JS 执行之前,把 window.xchat 挂到 window 上。
// 同时接管 window._xchat_native 的赋值:一旦 Dart 侧通道就绪,立即
// 把 pending 队列里的所有请求 flush 出去,做到 0 延迟。
//
// 通道名: window._xchat_native 由 Dart 侧
//   WebViewController.addJavaScriptChannel('XchatNative', ...)
// 在 WebView 的 JS context 里挂上。bridge.js 比页面 IIFE 早,
// 因此能抢先定义 getter/setter,捕获第一次赋值。
(function () {
  if (window.xchat) return; // 防重复

  // ---- 1. _xchat_native 就绪队列 ----
  var pending = [];        // [{payload, cb, resolve, reject, deadline}, ...]
  var nativeReady = false;
  var TIMEOUT_MS = 5000;

  function flush() {
    if (!nativeReady) {
      if (!(window._xchat_native && window._xchat_native.postMessage) &&
          !window.webkit) return;
      nativeReady = true;
    }
    var now = Date.now();
    var remain = [];
    for (var i = 0; i < pending.length; i++) {
      var it = pending[i];
      if (it.deadline <= now) {
        delete window[it.cb];
        it.reject({ error: 'bridge channel not ready (timeout)' });
        continue;
      }
      try {
        // window._xchat_native 包装层(若已注入)
        if (window._xchat_native && window._xchat_native.postMessage) {
          window._xchat_native.postMessage(it.payload);
          remain.push(it);
          continue;
        }
        // WebKit 原生 channel
        if (nativePost(it.payload)) {
          remain.push(it);
          continue;
        }
        remain.push(it); // 通道瞬时不可用,等下一次 flush
      } catch (e) {
        delete window[it.cb];
        it.reject({ error: 'postMessage failed: ' + (e && e.message || e) });
      }
    }
    pending = remain;
  }

  // 用 defineProperty 监听 _xchat_native 第一次被 Dart 注入
  try {
    var _desc = Object.getOwnPropertyDescriptor(window, '_xchat_native');
    // 多数情况下 webview_all 直接 window._xchat_native = {...}
    // 这种赋值走原生 setter,defineProperty 截不到。所以下面用
    // setInterval 兜底(代价是每 100ms 一次),见下方。
  } catch (e) {}

  // 兜底轮询。defineProperty 在赋值语句上不生效(赋值走 [[Set]],
  // 不会触发 Object.defineProperty 的 setter,除非显式走它)。
  // 因此这里退化为短轮询,但只在 _xchat_native 还没就绪时跑,
  // 就绪后立刻 clearInterval,不影响性能。
  var pollTimer = setInterval(function () {
    if (window._xchat_native && window._xchat_native.postMessage) {
      clearInterval(pollTimer);
      flush();
    }
  }, 100);

  // ---- 2. call / on / dispatch ----
  // 真正的 WebKit 原生 channel 入口。
  // webview_all_linux 通过 WebKitUserScript 把
  //   window.webkit.messageHandlers.<name>.postMessage(msg)
  // 暴露给 JS。比 window.<name>.postMessage 早,因为 channel 的
  // register_script_message_handler 在 webview 创建时就注册了。
  // 而 window.<name> = {...} 这个包装 user script 只在
  // addJavaScriptChannel 后才被 add 到 content_manager,所以会晚。
  var NATIVE_CHANNEL_NAME = 'XchatNative';

  function nativePost(msg) {
    var handlers = window.webkit && window.webkit.messageHandlers;
    if (handlers && handlers[NATIVE_CHANNEL_NAME]) {
      handlers[NATIVE_CHANNEL_NAME].postMessage(String(msg));
      return true;
    }
    return false;
  }

  function call(method, args) {
    return new Promise(function (resolve, reject) {
      var cb = '_xchat_cb_' + Date.now() + '_' + Math.floor(Math.random() * 1e6);
      window[cb] = function (ok, payload) {
        delete window[cb];
        if (ok) resolve(payload); else reject(payload);
      };
      var payload = JSON.stringify({ method: method, args: args || {}, cb: cb });

      // 1) 优先走 webview_all 注入的 window._xchat_native (兼容)
      if (window._xchat_native && window._xchat_native.postMessage) {
        try {
          window._xchat_native.postMessage(payload);
          return;
        } catch (e) { /* fall through to native */ }
      }
      // 2) 走 WebKit 原生 messageHandlers (webview_all_linux 实际工作路径)
      if (nativePost(payload)) return;
      // 3) 都没就绪 -> 短轮询兜底,等 5s
      pending.push({
        payload: payload,
        cb: cb,
        resolve: resolve,
        reject: reject,
        deadline: Date.now() + TIMEOUT_MS,
      });
    });
  }

  function on(event, handler) {
    if (!window._xchat_events) window._xchat_events = {};
    if (!window._xchat_events[event]) window._xchat_events[event] = [];
    window._xchat_events[event].push(handler);
  }

  // Dart 侧事件回调入口(由 webview_host.dart 的事件订阅器调用)
  window._xchat_dispatch = function (event, payload) {
    var arr = (window._xchat_events && window._xchat_events[event]) || [];
    for (var i = 0; i < arr.length; i++) {
      try { arr[i](payload); } catch (e) { /* 单个监听器出错不影响其他 */ }
    }
  };

  // 调试钩子: 控制台可见就绪状态
  window._xchat_ready = function () { return !!nativeReady; };

  // ---- 3. xchat API ----
  window.xchat = {
    config: {
      get: function () { return call('config.get', {}); },
      set: function (p) { return call('config.set', { patch: p }); },
      refreshFx: function () { return call('config.refreshFx', {}); },
      getBlocklist: function () { return call('config.getBlocklist', {}); },
      setBlocklist: function (p) { return call('config.setBlocklist', { patch: p }); },
      setConfirmMode: function (m) { return call('config.setConfirmMode', { mode: m }); },
    },
    templates: {
      list: function () { return call('templates.list', {}); },
      get: function (id) { return call('templates.get', { id: id }); },
      save: function (p) { return call('templates.save', p); },
      delete: function (id) { return call('templates.delete', { id: id }); },
      duplicate: function (id, name) { return call('templates.duplicate', { id: id, name: name || '' }); },
      listVars: function (id) { return call('templates.listVars', { id: id }); },
      openInEditor: function (id) { return call('templates.openInEditor', { id: id }); },
    },
    sessions: {
      list: function (q, opts) {
        opts = opts || {};
        return call('sessions.list', {
          query: q || '',
          tag: opts.tag || '',
          project_id: opts.project_id || '',
        });
      },
      get: function (id) { return call('sessions.get', { id: id }); },
      create: function (p) { return call('sessions.create', p); },
      delete: function (id) { return call('sessions.delete', { id: id }); },
      clone: function (id) { return call('sessions.clone', { id: id }); },
      cloneMeta: function (id) { return call('sessions.cloneMeta', { id: id }); },
      resend: function (id, text) { return call('sessions.resend', { id: id, text: text }); },
      openInEditor: function (id) { return call('sessions.openInEditor', { id: id }); },
      updateMeta: function (id, patch) { return call('sessions.updateMeta', { id: id, patch: patch }); },
      listTemplates: function () { return call('sessions.listTemplates', {}); },
      getTemplate: function (id) { return call('sessions.getTemplate', { id: id }); },
      setTags: function (id, tags) { return call('sessions.setTags', { id: id, tags: tags || [] }); },
      setProject: function (id, pid) { return call('sessions.setProject', { id: id, project_id: pid || null }); },
      listTags: function () { return call('sessions.listTags', {}); },
    },
    projects: {
      list: function () { return call('projects.list', {}); },
      create: function (name, color) { return call('projects.create', { name: name, color: color || null }); },
      rename: function (id, name, color) { return call('projects.rename', { id: id, name: name, color: color || null }); },
      delete: function (id) { return call('projects.delete', { id: id }); },
    },
    providers: {
      list: function () { return call('providers.list', {}); },
      get: function (id) { return call('providers.get', { id: id }); },
      upsert: function (p) { return call('providers.upsert', p); },
      delete: function (id) { return call('providers.delete', { id: id }); },
      test: function (id, mid) { return call('providers.test', { id: id, model_id: mid || null }); },
    },
    chat: {
      send: function (sid, text) { return call('chat.send', { sessionId: sid, text: text }); },
      stop: function (sid) { return call('chat.stop', { sessionId: sid }); },
      confirmTool: function (sid, cid, decision) {
        return call('chat.confirmTool', { sessionId: sid, callId: cid, decision: decision });
      },
      // 修复 #4: JS mount 完成(订阅 xchat.events.on 的代码已就绪)后通知 Dart,
      // 让 Dart 把 ready 之前缓冲的事件回灌给前端。这样在 chat.send 早于 JS ready
      // 的极端时序下,前端也不会丢掉 setRunning(false) 所需的终止事件。
      notifyReady: function () { return call('chat.ready', {}); },
    },
    events: { on: on },
  };

  // 自动通知 Dart 已就绪;延迟到下一个 tick,确保 events.on 的订阅者先注册。
  Promise.resolve().then(function () {
    if (window.xchat && window.xchat.chat && window.xchat.chat.notifyReady) {
      window.xchat.chat.notifyReady().then(function (res) {
        var pending = (res && res.pending) || [];
        for (var i = 0; i < pending.length; i++) {
          var ev = pending[i];
          try { window._xchat_dispatch(ev.event, ev.payload); } catch (e) {}
        }
        if (pending.length) console.log('[xchat] drained ' + pending.length + ' pending events');
      }).catch(function (e) { console.warn('[xchat] notifyReady failed', e); });
    }
  });

  console.log('bridge.js loaded; window.xchat ready, waiting for native channel');
})();
