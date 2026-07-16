const API_BASE = window.location.protocol === "file:" ? "http://localhost:8788" : "";
const toast = document.getElementById("toast");

setupLinkScraper({
  formId: "extract-form",
  textId: "query-text",
  imageInputId: "image-input",
  previewId: "image-preview",
  submitId: "submit-button",
  clearId: "clear-button",
  resultId: "result-panel",
  titleId: "result-title",
  rowsId: "result-rows",
  downloadId: "download-link",
  endpoint: "/api/extract",
});

setupProfileExporter({
  formId: "profile-form",
  urlId: "profile-url",
  countId: "video-count",
  chartId: "generate-chart",
  buttonId: "profile-button",
  statusId: "profile-status",
  resultId: "profile-result",
  summaryId: "profile-file-summary",
  downloadListId: "profile-download-list",
  endpoint: "/api/profile/extract",
  defaultFileName: "TikTok主页视频数据.xlsx",
});

setupVideoExporter({
  formId: "video-file-form",
  inputId: "video-file-url",
  buttonId: "video-file-button",
  statusId: "video-file-status",
  resultId: "video-file-result",
  summaryId: "video-file-summary",
  downloadId: "video-file-download",
  endpoint: "/api/video-file/extract",
  bodyKey: "videoUrl",
  emptyMessage: "请输入 TikTok 视频链接",
  loadingMessage: "正在提取 MP4 文件",
  successToast: "MP4 文件已生成",
  idleText: "提取MP4文件",
});

setupLinkScraper({
  formId: "instagram-link-form",
  textId: "instagram-query-text",
  imageInputId: "instagram-image-input",
  previewId: "instagram-image-preview",
  submitId: "instagram-link-button",
  clearId: "instagram-link-clear",
  resultId: "instagram-link-result",
  titleId: "instagram-link-title",
  rowsId: "instagram-link-rows",
  downloadId: "instagram-link-download",
  endpoint: "/api/instagram/link-extract",
});

setupProfileExporter({
  formId: "instagram-profile-form",
  urlId: "instagram-profile-url",
  countId: "instagram-video-count",
  chartId: "instagram-generate-chart",
  buttonId: "instagram-profile-button",
  statusId: "instagram-profile-status",
  resultId: "instagram-profile-result",
  summaryId: "instagram-profile-summary",
  downloadListId: "instagram-profile-download-list",
  endpoint: "/api/instagram/profile/extract",
  defaultFileName: "Instagram主页视频数据.xlsx",
});

setupVideoExporter({
  formId: "instagram-form",
  inputId: "instagram-url",
  buttonId: "instagram-button",
  statusId: "instagram-status",
  resultId: "instagram-result",
  summaryId: "instagram-summary",
  downloadId: "instagram-download",
  endpoint: "/api/instagram/extract",
  bodyKey: "instagramUrl",
  emptyMessage: "请输入 Instagram 视频链接",
  loadingMessage: "正在提取 MP4 文件",
  successToast: "Instagram MP4 文件已生成",
  idleText: "提取MP4文件",
});

function setupLinkScraper(config) {
  const form = document.getElementById(config.formId);
  const queryText = document.getElementById(config.textId);
  const imageInput = document.getElementById(config.imageInputId);
  const imagePreview = document.getElementById(config.previewId);
  const submitButton = document.getElementById(config.submitId);
  const clearButton = document.getElementById(config.clearId);
  const resultPanel = document.getElementById(config.resultId);
  const resultTitle = document.getElementById(config.titleId);
  const resultRows = document.getElementById(config.rowsId);
  const downloadLink = document.getElementById(config.downloadId);

  if (!form) return;

  let selectedImages = [];

  imageInput.addEventListener("change", async () => {
    const files = Array.from(imageInput.files || []);
    selectedImages = [];
    imagePreview.innerHTML = "";

    for (const file of files) {
      const meta = await analyzeImage(file);
      selectedImages.push(meta);
      imagePreview.appendChild(renderThumb(meta));
    }
  });

  clearButton.addEventListener("click", () => {
    form.reset();
    selectedImages = [];
    imagePreview.innerHTML = "";
    resultPanel.hidden = true;
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const text = queryText.value.trim();
    if (!text) {
      showToast("请输入文本", true);
      return;
    }

    submitButton.disabled = true;
    submitButton.textContent = "生成中";

    try {
      const imagesForServer = selectedImages.map(({ previewUrl, ...image }) => image);
      const response = await fetch(`${API_BASE}${config.endpoint}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, images: imagesForServer }),
      });
      const payload = await response.json();
      if (!response.ok || !payload.ok) throw new Error(payload.error || "生成失败");

      renderLinkResult(payload, resultPanel, resultTitle, resultRows, downloadLink);
      showToast("表格已生成");
    } catch (error) {
      showToast(error.message || "生成失败", true);
    } finally {
      submitButton.disabled = false;
      submitButton.textContent = "提取视频链接";
    }
  });
}

function setupProfileExporter(config) {
  const form = document.getElementById(config.formId);
  const profileInput = document.getElementById(config.urlId);
  const countInput = document.getElementById(config.countId);
  const chartInput = document.getElementById(config.chartId);
  const profileButton = document.getElementById(config.buttonId);
  const profileStatus = document.getElementById(config.statusId);
  const profileResult = document.getElementById(config.resultId);
  const profileFileSummary = document.getElementById(config.summaryId);
  const profileDownloadList = document.getElementById(config.downloadListId);

  if (!form) return;

  let downloadUrls = [];

  const setStatus = (message, isError = false) => {
    profileStatus.textContent = message;
    profileStatus.classList.toggle("error", isError);
  };

  const revokeDownloads = () => {
    for (const url of downloadUrls) URL.revokeObjectURL(url);
    downloadUrls = [];
    profileDownloadList.replaceChildren();
  };

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const profileUrl = profileInput.value.trim();
    const count = Number.parseInt(countInput.value, 10);
    const generateChart = chartInput.checked;

    if (!profileUrl || !Number.isFinite(count) || count < 1) {
      setStatus("请检查主页链接和提取数量", true);
      return;
    }

    revokeDownloads();
    profileResult.hidden = true;
    profileButton.disabled = true;
    profileButton.textContent = "提取中";
    setStatus(generateChart ? "正在提取数据并生成图表" : "正在提取数据");

    try {
      const response = await fetch(`${API_BASE}${config.endpoint}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ profileUrl, count, generateChart }),
      });

      if (!response.ok) {
        let message = "提取失败";
        try {
          const error = await response.json();
          message = error.error || message;
        } catch {
          message = await response.text();
        }
        throw new Error(message);
      }

      const blob = await response.blob();
      const fileName = getFileName(response, config.defaultFileName);
      addDownload(profileDownloadList, downloadUrls, fileName, blob, "下载表格");
      profileFileSummary.textContent = fileName;
      profileResult.hidden = false;

      const extracted = response.headers.get("x-extracted-count") || "";
      const total = response.headers.get("x-profile-video-count") || "";
      setStatus(total && extracted ? `已提取 ${extracted}/${total} 条视频` : "表格已生成");
    } catch (error) {
      setStatus(error.message || "提取失败", true);
    } finally {
      profileButton.disabled = false;
      profileButton.textContent = "生成数据分析表";
    }
  });
}

function setupVideoExporter(config) {
  const form = document.getElementById(config.formId);
  const input = document.getElementById(config.inputId);
  const button = document.getElementById(config.buttonId);
  const status = document.getElementById(config.statusId);
  const result = document.getElementById(config.resultId);
  const summary = document.getElementById(config.summaryId);
  const download = document.getElementById(config.downloadId);

  if (!form) return;

  const setStatus = (message, isError = false) => {
    status.textContent = message;
    status.classList.toggle("error", isError);
  };

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const url = input.value.trim();

    if (!url) {
      setStatus(config.emptyMessage, true);
      return;
    }

    result.hidden = true;
    button.disabled = true;
    button.textContent = "提取中";
    setStatus(config.loadingMessage);

    try {
      const response = await fetch(`${API_BASE}${config.endpoint}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ [config.bodyKey]: url }),
      });
      const payload = await response.json();
      if (!response.ok || !payload.ok) throw new Error(payload.error || "视频文件提取失败");

      summary.textContent = payload.fileName;
      download.href = `${API_BASE}${payload.downloadUrl}`;
      download.download = payload.fileName;
      result.hidden = false;
      setStatus(formatFileSize(payload.size));
      showToast(config.successToast);
    } catch (error) {
      setStatus(error.message || "视频文件提取失败", true);
    } finally {
      button.disabled = false;
      button.textContent = config.idleText;
    }
  });
}

function addDownload(container, urlList, fileName, blob, label) {
  const url = URL.createObjectURL(blob);
  urlList.push(url);
  const link = document.createElement("a");
  link.className = "download-link";
  link.href = url;
  link.download = fileName;
  link.textContent = label;
  container.append(link);
}

function formatFileSize(size) {
  const bytes = Number(size);
  if (!Number.isFinite(bytes) || bytes <= 0) return "MP4 文件已生成";
  if (bytes < 1024 * 1024) return `MP4 文件已生成 · ${(bytes / 1024).toFixed(1)} KB`;
  return `MP4 文件已生成 · ${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function getFileName(response, fallback) {
  const disposition = response.headers.get("content-disposition") || "";
  const utf8Match = disposition.match(/filename\*=UTF-8''([^;]+)/i);
  if (utf8Match) return decodeURIComponent(utf8Match[1]);
  const asciiMatch = disposition.match(/filename="?([^";]+)"?/i);
  return asciiMatch ? asciiMatch[1] : fallback;
}

async function analyzeImage(file) {
  const objectUrl = URL.createObjectURL(file);
  const img = await loadImage(objectUrl);
  const colors = getImageColors(img);
  const hash = await hashFile(file);

  return {
    name: file.name,
    size: file.size,
    type: file.type,
    width: img.naturalWidth,
    height: img.naturalHeight,
    colors,
    hash,
    previewUrl: objectUrl,
  };
}

async function hashFile(file) {
  if (!window.crypto?.subtle) {
    return `${file.name}:${file.size}:${file.lastModified}`;
  }
  const buffer = await file.arrayBuffer();
  const digest = await window.crypto.subtle.digest("SHA-256", buffer);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function loadImage(src) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = reject;
    img.src = src;
  });
}

function getImageColors(img) {
  const canvas = document.createElement("canvas");
  const size = 64;
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(img, 0, 0, size, size);
  const data = ctx.getImageData(0, 0, size, size).data;
  const buckets = new Map();

  for (let i = 0; i < data.length; i += 16) {
    const r = data[i];
    const g = data[i + 1];
    const b = data[i + 2];
    const a = data[i + 3];
    if (a < 180) continue;
    const color = classifyColor(r, g, b);
    buckets.set(color, (buckets.get(color) || 0) + 1);
  }

  const ranked = Array.from(buckets.entries())
    .sort((a, b) => b[1] - a[1])
    .map(([name]) => name);
  const withoutWhite = ranked.filter((name) => name !== "white");
  return (withoutWhite.length ? withoutWhite : ranked).slice(0, 3);
}

function classifyColor(r, g, b) {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  if (max < 58) return "black";
  if (max < 105 && delta < 28) return "dark gray";
  if (min > 226 && delta < 24) return "white";
  if (delta < 24) return "gray";
  if (r > 130 && g < 95 && b < 95) return "red";
  if (r > 150 && g > 95 && g < 165 && b < 90) return "orange";
  if (r > 145 && g > 130 && b < 95) return "yellow";
  if (g > 115 && r < 125 && b < 125) return "green";
  if (b > 125 && r < 125 && g < 150) return "blue";
  if (r > 120 && b > 115 && g < 115) return "purple";
  if (r > 120 && g > 70 && b < 65) return "brown";
  return "mixed";
}

function renderThumb(meta) {
  const item = document.createElement("div");
  item.className = "thumb";
  item.innerHTML = `
    <img src="${meta.previewUrl}" alt="${escapeHtml(meta.name)}" />
    <span title="${escapeHtml(meta.name)}">${escapeHtml(meta.name)}</span>
  `;
  return item;
}

function renderLinkResult(payload, panel, title, rows, download) {
  panel.hidden = false;
  title.textContent = `已生成 ${payload.count} 条`;
  download.href = `${API_BASE}${payload.downloadUrl}`;
  download.download = payload.fileName;
  rows.innerHTML = "";

  payload.rows.forEach((row) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td><a href="${row.link}" target="_blank" rel="noreferrer">${row.link}</a></td>
    `;
    rows.appendChild(tr);
  });
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
