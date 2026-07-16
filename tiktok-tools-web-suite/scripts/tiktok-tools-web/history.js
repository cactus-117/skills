const historyList = document.getElementById("history-list");
const refreshHistory = document.getElementById("refresh-history");
const toast = document.getElementById("toast");
const API_BASE = window.location.protocol === "file:" ? "http://localhost:8788" : "";

const historyType = document.body.dataset.linkHistoryType || "tiktok-link";
const historyConfig = {
  "tiktok-link": {
    api: "/api/history",
    deleteApi: "/api/history/delete",
    empty: "暂无 TikTok 链接扒取历史文件",
  },
  "instagram-link": {
    api: "/api/instagram/link-history",
    deleteApi: "/api/instagram/link-history/delete",
    empty: "暂无 Instagram 链接扒取历史文件",
  },
};
const config = historyConfig[historyType] || historyConfig["tiktok-link"];

refreshHistory.addEventListener("click", loadHistory);
loadHistory();

async function loadHistory() {
  historyList.innerHTML = `<div class="empty">正在读取历史文件</div>`;

  try {
    const response = await fetch(`${API_BASE}${config.api}`);
    const payload = await response.json();
    const items = payload.items || [];
    historyList.innerHTML = "";

    if (!items.length) {
      historyList.innerHTML = `<div class="empty">${config.empty}</div>`;
      return;
    }

    items.forEach((item) => {
      const node = document.createElement("div");
      node.className = "history-item";
      node.innerHTML = `
        <div>
          <strong>${escapeHtml(item.fileName)}</strong>
          <div class="history-meta">${escapeHtml(item.createdAt)} · ${item.rowCount} 条 · ${escapeHtml(item.text || "")}</div>
        </div>
        <div class="history-actions">
          <a class="download-link" href="${API_BASE}${item.downloadUrl}" download>下载</a>
          <button class="danger" type="button" data-delete-id="${escapeHtml(item.id)}">删除</button>
        </div>
      `;
      node.querySelector("[data-delete-id]").addEventListener("click", () => deleteHistoryItem(item.id));
      historyList.appendChild(node);
    });
  } catch {
    historyList.innerHTML = `<div class="empty">历史记录读取失败</div>`;
  }
}

async function deleteHistoryItem(id) {
  if (!window.confirm("确认删除这个历史文件吗？")) return;

  try {
    const response = await fetch(`${API_BASE}${config.deleteApi}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id }),
    });
    const payload = await response.json();
    if (!response.ok || !payload.ok) throw new Error(payload.error || "删除失败");
    await loadHistory();
    showToast("已删除");
  } catch (error) {
    showToast(error.message || "删除失败", true);
  }
}

function showToast(message, isError = false) {
  toast.textContent = message;
  toast.classList.toggle("error", isError);
  toast.classList.add("show");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.remove("show"), 2200);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
