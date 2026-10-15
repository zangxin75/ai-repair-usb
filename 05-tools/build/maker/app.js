/* AI 维修 U盘 自助页 v0.3.1
 * 余额/Key 管理统一走 tokeneff.com 登录（制作时邮箱验证+设密码即注册），
 * 本页只保留三件事：系统 Tab 切换、复制安装命令、手动组件清单渲染。 */

/* ── Tab 切换（Windows / Linux） ── */
document.querySelectorAll(".tab").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((b) => {
      b.classList.toggle("active", b === btn);
      b.setAttribute("aria-selected", b === btn ? "true" : "false");
    });
    document.querySelectorAll(".tabbody").forEach((p) => p.classList.add("hidden"));
    const panel = document.getElementById("tab-" + btn.dataset.tab);
    if (panel) panel.classList.remove("hidden");
  });
});

/* ── 复制安装命令 ── */
document.querySelectorAll(".btn.copy-cmd").forEach((btn) => {
  btn.addEventListener("click", async () => {
    const el = document.getElementById(btn.dataset.target);
    if (!el) return;
    const text = el.textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // 非安全上下文（http）或旧浏览器：execCommand 兜底
      const ta = document.createElement("textarea");
      ta.value = text; document.body.appendChild(ta); ta.select();
      document.execCommand("copy"); ta.remove();
    }
    const old = btn.textContent;
    btn.textContent = "已复制 ✓";
    setTimeout(() => (btn.textContent = old), 1500);
  });
});

/* ── 手动下载组件清单（manifest.json） ── */
(async () => {
  const box = document.getElementById("dl-list");
  if (!box) return;
  try {
    const r = await fetch("/maker/manifest.json", { cache: "no-cache" });
    if (!r.ok) throw new Error(r.status);
    const m = await r.json();
    box.innerHTML = (m.components || [])
      .map((c) => {
        const size = c.sizeBytes > 0 ? (c.sizeBytes / 1073741824).toFixed(2) + " GB" : "";
        if (c.url) {
          return `<div><a href="${c.url}" download>${c.filename}</a>${size ? " · " + size : ""}</div>`;
        }
        // 微软官方镜像：制作命令运行时向微软动态换取直链（始终从微软服务器下载）
        if (c.source === "microsoft-fido") {
          return `<div>${c.filename} · 由制作命令运行时向微软官网自动获取直链（<a href="${c.sourceUrl}" target="_blank" rel="noopener">官方下载页</a>，也可手动下载后拷入 U盘）</div>`;
        }
        // 自产组件尚未发布：制作时跳过，不阻断
        return `<div>${c.filename} · 暂未发布（后续版本自动包含，当前制作时自动跳过）</div>`;
      })
      .join("");
  } catch {
    box.textContent = "组件清单读取失败，可直接使用上方安装命令（全自动）。";
  }
})();
