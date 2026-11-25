# PanLink_Lite

PanLink Lite 百度下載管理器 v2.0.0 · hardened-20261125

基於 [PanLink Lite v1.8.1](https://github.com/limousine-tony/panlink-lite) 的百度專用自訂版本。AGPL-3.0-or-later。

## 安裝與驗收

- [完整 UserScript](panlink-lite-baidu-v2.0.0.user.js)
- [純文字替換版](panlink-lite-baidu-v2.0.0.txt)
- [操作說明與已知限制](README.txt)
- [本機唯讀校驗工具](Verify-BaiduDownloads.ps1)
- [自動化測試](test-panlink-v2.0.0.cjs) 與 [測試結果](test-results.txt)
- [SHA256 校驗清單](SHA256SUMS.txt)
- [授權文件](LICENSE)

```sh
node --check panlink-lite-baidu-v2.0.0.user.js
node test-panlink-v2.0.0.cjs
```

64 項模擬情境測試已通過。2026-11-25 使用者確認 Windows／Edge／百度網盤日常實機操作正常，UI 已接受；以此凍結 v2.0.0 功能基準。各項異常恢復、自適應長時間運行及 Windows 校驗工具未取得逐項實機驗收證據，仍列為待觀察項目。請勿提交帳號憑證、下載直鏈或下載紀錄。

### 介面更新（版本維持 2.0.0）

設定分為連線與保存目錄、下載效能、進階設定；使用有邊框的輸入框、下拉選單及勾選框。管理器保留常用操作，其他操作集中於「更多操作」，任務顯示中文狀態與個別進度條。RPC 測試使用已保存的設定。下載引擎、設定鍵與佇列格式不變。原有 64 項模擬測試重新通過；本機 Chromium 模擬頁檢查表單與窄視窗排版通過，後續已獲使用者日常操作正常及 UI 確認。

## 版本與維護

- [版本更新紀錄](CHANGELOG.md)
- [v2.0.0 發布說明](RELEASE_NOTES.md)
- [驗收紀錄](docs/v2.0.0-acceptance.md)

已驗收腳本基準：[c8a3cb6](https://github.com/h104651/PanLink_Lite/commit/c8a3cb69f91f0d6a752cb14573e3be6c787ba69f)。本次收尾僅更新文件，不更動下載引擎、腳本或校驗工具。後續以實際缺陷修復為主。
