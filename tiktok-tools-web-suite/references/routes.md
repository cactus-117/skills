# Route Map

Main service: `scripts/tiktok-tools-web/server.ps1`

## Pages

- `/` or `/index.html`: two-workspace main UI.
- `/history.html`: TikTok video link Excel history.
- `/profile-history.html`: TikTok profile data analysis Excel history.
- `/video-file-history.html`: TikTok MP4 extraction history.
- `/instagram-link-history.html`: Instagram video link Excel history.
- `/instagram-profile-history.html`: Instagram profile data analysis Excel history.
- `/instagram-history.html`: Instagram MP4 extraction history.

## APIs

- `POST /api/extract`: text + image metadata to TikTok video links and `.xlsx`.
- `GET /api/history`: TikTok video link Excel history.
- `POST /api/history/delete`: delete TikTok video link Excel history item.
- `POST /api/profile/extract`: TikTok profile data analysis Excel export.
- `GET /api/profile/history`: TikTok profile Excel history.
- `POST /api/profile/history/delete`: delete TikTok profile Excel history item.
- `POST /api/video-file/extract`: TikTok video URL to MP4.
- `GET /api/video-file/history`: TikTok MP4 history.
- `POST /api/video-file/history/delete`: delete TikTok MP4 history item.
- `POST /api/instagram/link-extract`: text + image metadata to Instagram video links and `.xlsx`.
- `GET /api/instagram/link-history`: Instagram video link Excel history.
- `POST /api/instagram/link-history/delete`: delete Instagram video link Excel history item.
- `POST /api/instagram/profile/extract`: Instagram profile data analysis Excel export.
- `GET /api/instagram/profile/history`: Instagram profile Excel history.
- `POST /api/instagram/profile/history/delete`: delete Instagram profile Excel history item.
- `POST /api/instagram/extract`: Instagram Reel/video URL to MP4.
- `GET /api/instagram/history`: Instagram MP4 history.
- `POST /api/instagram/history/delete`: delete Instagram MP4 history item.

## Downloads

- `/download/<file>`: TikTok link `.xlsx` from `scripts/tiktok-tools-web/exports/`.
- `/profile-download/<id>`: TikTok profile `.xlsx` from `scripts/tiktok-tools-web/profile_exports/`.
- `/video-download/<file>`: TikTok MP4 from `scripts/downloads/tiktok/`.
- `/instagram-link-download/<file>`: Instagram link `.xlsx` from `scripts/tiktok-tools-web/instagram_exports/`.
- `/instagram-profile-download/<id>`: Instagram profile `.xlsx` from `scripts/tiktok-tools-web/instagram_profile_exports/`.
- `/instagram-download/<file>`: Instagram MP4 from `scripts/downloads/instagram/`.

## Runtime Data

- `scripts/tiktok-tools-web/data/history.json`
- `scripts/tiktok-tools-web/data/profile-history.json`
- `scripts/tiktok-tools-web/data/video-file-history.json`
- `scripts/tiktok-tools-web/data/instagram-link-history.json`
- `scripts/tiktok-tools-web/data/instagram-profile-history.json`
- `scripts/tiktok-tools-web/data/instagram-history.json`
