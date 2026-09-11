(function() {
  Router.on('#/cost', async function(main) {
    const cfg = await xchat.config.get();
    main.innerHTML = `
      <div class="row" style="margin-bottom:12px">
        <strong>成本面板</strong>
        <span class="muted">币种:</span>
        <select id="cur">
          ${['CNY','USD','EUR','JPY'].map(c=>`<option value="${c}" ${c===cfg.ui.currency?'selected':''}>${c}</option>`).join('')}
        </select>
        <button class="btn" id="refresh">刷新汇率</button>
        <span class="muted" id="fx"></span>
      </div>
      <div class="card"><h3>本机所有会话累计</h3><div id="agg"></div></div>
    `;
    const cur = main.querySelector('#cur'); const fx = main.querySelector('#fx');
    cur.onchange = async () => { await xchat.config.set({ui:{currency:cur.value}}); draw(); };
    main.querySelector('#refresh').onclick = async () => { await xchat.config.refreshFx(); draw(); };
    draw();

    async function draw() {
      const cfg2 = await xchat.config.get();
      const rates = cfg2.ui.fx_rates;
      fx.textContent = `汇率: 1 USD = ${rates[cur.value]} ${cur.value}`;
      const list = await xchat.sessions.list();
      const providers = cfg2.providers || [];
      // 聚合按 model
      const byModel = {};
      for (const it of list) {
        const m = it.model_id || 'unknown';
        if (!byModel[m]) byModel[m] = {in:0, out:0, cache:0};
        byModel[m].in += it.total_input; byModel[m].out += it.total_output; byModel[m].cache += it.total_cache;
      }
      const rows = Object.entries(byModel).map(([m,v]) => {
        const p = _priceOf(providers, m);
        // 价格存储约定是 CNY / 1M tokens,直接按 CNY 算出成本再换显示币种。
        const cny = (v.in*p.in + v.out*p.out + v.cache*p.cache)/1e6;
        // CNY -> USD(除以 rates.CNY,因 rates 是"1 USD = X 目标"的方向) -> 用户选定币种。
        const cnyRate = rates.CNY || 7.25;
        const disp = cny / cnyRate * (rates[cur.value] || 1);
        return `<tr><td>${esc(m)}</td><td>${v.in}</td><td>${v.out}</td><td>${v.cache}</td><td>${disp.toFixed(4)} ${cur.value}</td></tr>`;
      }).join('');
      main.querySelector('#agg').innerHTML = `
        <table style="width:100%;border-collapse:collapse">
          <tr><th>Model</th><th>Input</th><th>Output</th><th>Cache</th><th>Cost</th></tr>
          ${rows || '<tr><td colspan=5 class="muted">无数据</td></tr>'}
        </table>
      `;
    }

    function _priceOf(providers, modelId) {
      for (const p of providers) for (const m of p.models||[]) if (m.id===modelId) return m.pricing || {in:0,out:0,cache:0};
      return {in:0,out:0,cache:0};
    }
  });
  function esc(s) { return String(s||'').replace(/&/g,'&').replace(/</g,'<').replace(/>/g,'>'); }
})();
