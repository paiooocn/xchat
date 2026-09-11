// Mermaid 占位: 没有外网和 mermain 库,这里给一个结构化的代码预览块,
// 把流程图/时序图原文以等宽 + 行号展示,并提示用户。
// 后续若引入 mermaid 库,只需把 renderPlaceholder 替换为:
//   const g = new mermaid.mermaidAPI.render(id, code); return g;
// 即可,上游接口不变。
window.MarkdownMermaid = (function () {
  function renderPlaceholder(code) {
    const id = 'mmd-' + Math.random().toString(36).slice(2, 8);
    const preview = escapeHTML(code).replace(/\n/g, '<br>');
    return (
      '<div class="mermaid-placeholder" data-mermaid="1" data-mermaid-src="' +
      escapeHTML(code.length > 1000 ? code.slice(0, 1000) + '\n…(truncated)' : code) +
      '">' +
        '<div class="mermaid-head">📊 Mermaid 图表 <span class="muted">(未安装 mermaid 库,显示源码)</span></div>' +
        '<pre class="mermaid-code"><code>' + preview + '</code></pre>' +
      '</div>'
    );
  }
  function escapeHTML(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  return { renderPlaceholder };
})();
