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

64 項模擬情境測試已通過。尚未完成 Windows、Edge、百度 SVIP 整合實機驗收；目前為驗收候選版本。請勿提交帳號憑證、下載直鏈或下載紀錄。

### 介面更新（版本維持 2.0.0）

設定分為連線與保存目錄、下載效能、進階設定；使用有邊框的輸入框、下拉選單及勾選框。管理器保留常用操作，其他操作集中於「更多操作」，任務顯示中文狀態與個別進度條。RPC 測試使用已保存的設定。下載引擎、設定鍵與佇列格式不變。原有 64 項模擬測試重新通過；本機 Chromium 模擬頁檢查表單與窄視窗排版通過，尚未完成真實百度頁面驗收。
