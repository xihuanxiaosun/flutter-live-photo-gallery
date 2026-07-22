# 真机验证清单（无人值守重构 · 需人工在设备上过一遍）

> 本文件列出**无法在 CI/无头环境自动验证**、需要你在真机上确认的项。
> 已自动验证的部分（不需要你手动测）：Dart `flutter analyze` + 12 个单测、Android 75 个 JVM 单测、
> Android debug/release 编译。**iOS 完全无法在开发机的无头环境编译/运行，所以 iOS 项全部需要你真机确认。**
>
> 图例：`[ ]` 待验证 · 分支 `refactor/cleanup-and-bugfixes`

## ⚠️ 先看这条：往 `ios/Classes/` 加过文件后必须 `pod install`

podspec 用的是通配符 `Classes/**/*.swift`，但**这个通配符是在 `pod install` 时展开并写死进 Pods 工程的**。
新增 Swift 文件不会改变 podspec 校验和，所以 Flutter **不会**自动重装 pod，构建就会报
`Cannot find 'XXX' in scope`（看起来像重构失败，其实只是 Pods 工程是旧的）。

```bash
export LANG=en_US.UTF-8      # CocoaPods 需要 UTF-8 locale，否则 pod 会崩
cd example/ios && pod install
```

> 本轮我已经执行过 `pod install` 并跑通了真实构建（`✓ Built Runner.app`），
> 所以你现在直接 `flutter build ios` 就能成功。这条是给**以后**再加文件时看的。

---

## P. Pigeon 迁移后的全流程回归（本轮最需要覆盖）

消息层已从手写 MethodChannel 换成 Pigeon 生成的类型安全接口。**公共 Dart 用法一个字没变**，
但底层三端管道整个换掉了，所以每条通路都要真机走一遍：

- [ ] **`requestPermission()`** 返回 `authorized` / `limited` / `denied` / `notDetermined` 四种值正确
- [ ] **`pickAssets()`** 正常打开、选择、完成 → 返回 items 与 isOriginalPhoto 正确
- [ ] **`pickAssets()` 用户取消** → 返回 `null`（不是异常、不是空列表）
- [ ] **`previewAssets()`** 本地+网络混合预览正常；关闭/完成都能拿到结果
- [ ] **`previewAssets()` 取消** → 返回 `null`
- [ ] **`getThumbnail()`** 返回可用路径
- [ ] **`exportAsset()`** 三种 format（image / video / livePhotoVideo）都能导出
- [ ] **`exportAsset()` 传错误 format** → 抛 `LivePhotoException(code: 'INVALID_ARGS')`
- [ ] **`cleanupTempFiles()`** 不报错
- [ ] **三个事件流**：`onDownloadResult`（成功+失败）、`onDownloadProgress`（进度递增）、`onMaxCountReached`（超出上限时触发）——都能在 Flutter 侧收到
- [ ] **错误码**：权限拒绝时 `LivePhotoException.code == 'PERMISSION_DENIED'`；其余结构化错误码照旧
- [ ] **Android 权限流**：首次调用自动弹权限框，授予后自动继续打开选择器

## 如何运行

- **iOS**：`cd example && flutter run`（真机或模拟器；Live Photo 需真机相册里有 Live Photo）
- **Android**：`cd example && flutter run`（真机；Android 14 项需要 API 34+ 设备/模拟器）
- 建议 iOS 用有 Live Photo、Android 用有 Motion Photo（Pixel/Samsung）的真机各测一遍。

---

## A. iOS — Phase 1 修复（最高优先级，我完全没法自动验证）

- [ ] **打开错图修复**：相册里混入「无创建时间」的资源（如某些导入/截图），进选择器点不同格子，确认**打开的预览始终是所点那张**（此前 `createDate` 非确定性会串位）。
- [ ] **Live Photo 长按播放竞态**：预览页对着 Live Photo **快速长按后立刻松手**，多次重复。确认松手后**不会**再突然自己播放；正常长按仍能播放、松手即停。
- [ ] **分享本地资源**：预览页分享一张**本地相册图片**到「信息/微信/存储」，确认接收方**真的拿到图片**（此前分享裸 PHAsset 会拿到空内容）；分享本地视频同理；分享网络图仍是链接。
- [ ] **previewAssets 空数据不崩**：传入一组**全部非法**的 assets（坏 URL / 失效 assetId）调 `previewAssets`，确认**不崩溃/不白屏**，按空结果正常返回。
- [ ] **crop 仍可用**：预览页编辑→裁剪（TOCropViewController）能正常裁剪并回写（本次未改 crop 逻辑，仅确认没被牵连）。

## B. Android — Phase 1 修复

- [ ] **Android 14「仅选择照片」端到端**（需 API 34+ 设备）：首次调用在系统弹窗选「选择照片」→ 只授权部分照片。确认：
  - [ ] 选择器/预览**能正常打开**，只显示已授权的照片（此前会反复弹窗、永远打不开）；
  - [ ] `requestPermission()` 返回 `"limited"`；
  - [ ] 之后再次进入不再无谓弹窗。
- [ ] **下载校验 HTTP 状态**：预览页对一个**返回 404/错误页**的图片 URL 点保存，确认**提示失败**（`onDownloadResult` 收到 failure），**不会**把错误页当图片存进相册。正常 URL 仍能保存成功。
- [ ] **相册面板与网格一致**：用 `filterConfig: videoOnly` 打开，确认相册下拉里**只列视频相册**（此前会混入图片相册/计数）；`imageOnly` 反之。
- [ ] **编辑图刷新不闪**：选图后编辑其中一张，确认**只有那张**刷新、网格不整体闪烁（此前 `notifyDataSetChanged` 会全量重载）。
- [ ] **网络分享走文本**：预览网络图点分享，确认分享出去的是**链接文本**（可被微信/浏览器识别），不是坏的 stream。
- [ ] **pre-Q 相册名**（API ≤ 28 设备，可选）：设 `saveAlbumName` 保存网络图，确认落到 `Pictures/<相册名>/`。

## C. Android — 重构冒烟（M2 进行中；逻辑已被单测覆盖，仅需流程确认）

> 以下改动的**决策逻辑已有 JVM 单测覆盖**（`AssetSelectionId`/`DownloadMetadata`/`PreviewResultParser`/`SelectionLimits`），
> 真机只需确认「整体流程没被接线改动破坏」：

- [ ] **多选上限**：`maxCount`/`maxVideoCount` 限制在**选择器页**与**预览页**都仍生效、文案正确、`onMaxCountReached` 仍回调。
- [ ] **网络资源选择 round-trip**：混合本地+网络预览，勾选几个网络图，返回后再进预览，确认**之前的勾选还在**（依赖 `AssetSelectionId` 稳定 id）。
- [ ] **下载文件名/类型**：保存 png/webp 网络图，确认相册里扩展名/类型正确。

---

## D. Tier-B 控制器重构（无人值守推进中；仅编译验证，需真机冒烟）

> 这些批次把有状态代码从 Activity 搬进独立控制器，**行为应完全不变**，但无法 JVM 单测——请真机确认对应流程。

- [ ] **`MediaDownloader`（下载 IO + 存相册）**：预览网络图点保存 —— 进度回调、成功 Toast「已保存到相册」、失败回执、`Pictures/<saveAlbumName>/` 落盘、404 报失败，全部与之前一致。
- [ ] **`PreviewShareController`（分享）**：预览页分享本地图/视频（走系统分享面板、接收方拿到内容）、分享网络图（走链接文本），与之前一致。
- [ ] **`VideoPlaybackController`（内联视频/ExoPlayer）**：预览页点视频播放、左右翻页切视频（旧页停止、新页播放）、滑动回收后不串画面、退出页面释放播放器、autoPlayVideo 自动播放 —— 全部与之前一致（对应蓝图 R6）。
- [ ] **`AlbumBottomSheet`（相册选择弹层）**：点标题打开相册弹层、列表/封面/选中勾正常、切相册后标题更新+筛选重置+选中清空+重新加载、点外部关闭、标题箭头收起 —— 全部与之前一致。
- [ ] **`ToolbarTitleController`（工具栏标题）**：标题文字显示当前相册名、点标题打开相册弹层、箭头随弹层展开/收起旋转 —— 与之前一致。

## E2. iOS 深度拆分（M4 第一轮）—— 已通过**真类型检查**

> 好消息：本机其实有完整 Xcode 工具链，现在每次 iOS 改动都跑
> `swiftc -typecheck`（全部 ios/Classes 源码 + iPhoneOS SDK + example 已构建 framework），
> 当前 **exit 0 / 0 errors**。所以下面这些不再是"盲写"，但**类型对 ≠ 行为对**，仍需真机确认。
>
> **本轮结构变化**：`PhotoLibraryManager` 679→162 行（facade，内部拆 9 个服务，全局唯一
> `PHCachingImageManager` 注入所有服务）；`PhotoPreviewPageViewController` 1840→1334 行
> （拆出 4 个协作者）。合并了两套 AVPlayer 引擎与两处 AVAssetExportSession 异步桥。

- [ ] **Live Photo 长按播放（重点，修了一个真 bug）**：长按实况照片播放正常；**快速长按后立刻松手，反复十几次** —— 页面不得变**空白**，也不得松手后自己播放。（本轮修复：延迟播放块此前缺代次守卫，会在松手后把图层 alpha 置 0 却没有播放器，导致白屏。网络/本地文件来源的实况也一并加了守卫。）
- [ ] **视频播放**：点播放、暂停/继续、进度条、播放结束回到封面；左右翻页切视频（旧页停、新页可播）；退出预览释放播放器（无残留声音）。
- [ ] **裁剪流程**：预览页编辑→裁剪→完成，图片回写且缩略图刷新;取消裁剪回到预览。**边界**：裁剪页正在关闭时立刻下滑关闭预览 —— 不得出现"界面还在但点不动"（透明遮罩残留）。
- [ ] **网络图保存**：进度回调、成功 Toast、失败回执（404 应报失败）、保存到指定相册名。
- [ ] **分享**：分享本地图/本地视频（接收方拿到真实内容）、分享网络图（链接文本）。
- [ ] **相册与缩略图**：相册列表/切换/筛选正常；宫格滚动流畅、缩略图不错位（缓存预热与请求取消现在由同一个 PHCachingImageManager 承担，若滚动明显变卡请反馈）。
- [ ] **导出**：选图完成后导出原图/非原图、视频、实况视频均正常。
- [ ] **下拉关闭 & 飞入飞回转场**：手感与之前一致。

## E. iOS Phase 0 拆分 —— 首验 = 你在 Xcode 编译（已确认通过）

> 本环境无法编译 iOS。以下改动照蓝图精心写 + 括号/引用结构核验，但**第一关是你在 Xcode 能否编译通过**（很可能需要你修个别编译错误），之后再真机跑。按批次列出：
>
> - [ ] **首次 Xcode 编译通过**（`cd example && flutter build ios --no-codesign` 或直接开 Runner）—— 这是所有 iOS 批次的总闸。
> - [ ] **删死代码**（`resizeImage`/`loadNetworkLivePhoto`/`loadNetworkVideoThumbnail`/`LivePhotoError.invalidAsset`）—— 已复核 0 调用者，编译应无影响。
>   - 真机无需专门验（纯删除未用代码）。
> - [ ] **`SelectionLimits`（选择上限，镜像 Android）**：预览页/宫格页 `maxCount`/`maxVideoCount` 限制仍生效、文案正确、`onMaxCountReached` 仍回调 —— 与之前一致。纯文件已 `swiftc -parse` 通过。
> - [ ] **`DismissGestureMath`（下拉关闭手势数学）**：预览页下拉关闭的缩放/平移/进度手感与之前一致。纯文件已 `swiftc -parse` 通过。
> - [ ] **网络图封面加载三分支合并**（image/video/livePhoto 逻辑本就相同）：预览网络图/网络视频封面/网络实况封面仍正常显示。
> - [ ] **`SelectionBadgeRenderer`（选择徽标绘制）**：预览页选择按钮的圆圈勾选态/序号徽标显示正常（形状、对勾、数字居中）。**iOS Phase 0 拆分到此完成。**

## 剩余里程碑（越过"可无人值守安全验证"边界，需人工/真机主导）

自动重构在此**主动停止**——以下工作要么只能编译验证、真机敏感,要么需三端原子切换/真机回归,继续无人值守会违背"不盲赌到不可回退"。建议按下述方式人工推进:

- **Tier-C ChromeFader / 转场拆分（Android）**：仅编译验证、R1/R2/R4/R12 时序敏感。可做，但每步需真机确认飞入/飞回/下拉关闭动画无回归。收益是 PreviewActivity 再减 ~100 行。
- **M3 Pigeon 契约迁移**（你最看重的跨端根治）：需**一次性协调三端** + 真机回归。不可增量半迁移(Dart 切了 native 没切会运行时断,而 CI 只能测编译)。建议：新分支专做、pigeon 生成后 Dart+Android+iOS 一起改、真机全流程回归后再合。
- **M4 iOS 拆分**：`PhotoPreviewPageViewController`(1813) 拆分 → 重点真机回归飞入/飞回转场、pinch-zoom、下拉关闭、双 AVPlayer 合并后的视频/Live Photo 播放（R1-R12 的 iOS 对应）。本环境无法编译 iOS,须在 Xcode 逐步做。
- **M5 系统框架内换（iOS）**：`PHLivePhotoView` 播放保真度、`PHAssetResource` 导出/存相册。真机验证。
