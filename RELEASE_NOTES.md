# PanLink Lite v2.0.0

2026-11-25 · 日常使用驗收通過，功能凍結。

## 主要功能

- 百度授權直鏈、資料夾遞迴下載、Aria2 RPC 並行下載及斷點續傳。
- 持久化佇列、任務接管、暫停／繼續、取消、重複防護及有限次錯誤恢復。
- 動態並行數、自適應效能（選配）、速度統計、403／429 保守暫停。
- 簡潔管理介面、設定分區、進度條與任務篩選。
- 選配 PowerShell 本機校驗及報告匯入；來源 MD5 相容性須確認。

## 安裝

- [完整 UserScript](panlink-lite-baidu-v2.0.0.user.js) 或 [純文字替換版](panlink-lite-baidu-v2.0.0.txt)
- [本機校驗工具](Verify-BaiduDownloads.ps1) · [SHA256 清單](SHA256SUMS.txt)
- [操作說明](README.txt)

已安裝並驗收同一腳本的使用者不需要重新安裝。推薦初始 3 檔並行、每檔 4 連線，自適應及嚴格 MD5 預設關閉。

## 驗收與限制

原有 64 項模擬情境測試及本機 Chromium 介面模擬測試通過；使用者確認新版 UI 可接受、日常實機操作正常。未取得長時間自適應、極端斷線及 Windows 校驗工具的逐項實機證據。Edge 關閉時僅 Aria2 已提交任務可繼續；OAuth 失效需重新授權，RPC 停止需重新啟動。

AGPL-3.0-or-later；基於上游 PanLink Lite v1.8.1。
