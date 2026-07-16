const form = document.querySelector("#extract-form");
const profileInput = document.querySelector("#profile-url");
const countInput = document.querySelector("#video-count");
const chartInput = document.querySelector("#generate-chart");
const button = document.querySelector("#extract-button");
const statusEl = document.querySelector("#status");
const resultEl = document.querySelector("#result");
const fileSummaryEl = document.querySelector("#file-summary");
const downloadList = document.querySelector("#download-list");

let lastUrls = [];

function setStatus(message, isError = false) {
  statusEl.textContent = message;
  statusEl.classList.toggle("error", isError);
}

function setLoading(isLoading) {
  button.disabled = isLoading;
  button.classList.toggle("loading", isLoading);
  button.querySelector(".button-label").textContent = isLoading ? "提取中" : "提取";
}

function getFileName(response) {
  const disposition = response.headers.get("content-disposition") || "";
  const utf8Match = disposition.match(/filename\*=UTF-8''([^;]+)/i);
  if (utf8Match) {
    return decodeURIComponent(utf8Match[1]);
  }
  const asciiMatch = disposition.match(/filename="?([^";]+)"?/i);
  return asciiMatch ? asciiMatch[1] : "TikTok视频数据.xlsx";
}

function revokeDownloads() {
  for (const url of lastUrls) {
    URL.revokeObjectURL(url);
  }
  lastUrls = [];
  downloadList.replaceChildren();
}

function base64ToBlob(base64, mimeType) {
  const binary = atob(base64);
  const length = binary.length;
  const bytes = new Uint8Array(length);
  for (let index = 0; index < length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return new Blob([bytes], { type: mimeType });
}

function addDownloadLink(fileName, blob, label) {
  const url = URL.createObjectURL(blob);
  lastUrls.push(url);

  const link = document.createElement("a");
  link.className = "download";
  link.href = url;
  link.download = fileName;
  link.textContent = label;
  downloadList.append(link);
}

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
  resultEl.hidden = true;
  setLoading(true);
  setStatus(generateChart ? "正在提取数据并生成图表" : "正在提取数据");

  try {
    const response = await fetch("/api/extract", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
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

    const extracted = response.headers.get("x-extracted-count") || "";
    const total = response.headers.get("x-profile-video-count") || "";
    const contentType = response.headers.get("content-type") || "";

    if (contentType.includes("application/json")) {
      const payload = await response.json();
      for (const file of payload.files) {
        const blob = base64ToBlob(file.base64, file.mimeType);
        addDownloadLink(file.fileName, blob, file.label);
      }
      fileSummaryEl.textContent = payload.files.map((file) => file.fileName).join("、");
    } else {
      const blob = await response.blob();
      const fileName = getFileName(response);
      addDownloadLink(fileName, blob, "下载表格");
      fileSummaryEl.textContent = fileName;
    }

    resultEl.hidden = false;

    const detail =
      total && extracted
        ? `已提取 ${extracted}/${total} 条视频`
        : generateChart
          ? "表格和图表已生成"
          : "表格已生成";
    setStatus(detail);
  } catch (error) {
    setStatus(error.message || "提取失败", true);
  } finally {
    setLoading(false);
  }
});
