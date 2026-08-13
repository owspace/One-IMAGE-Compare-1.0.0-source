# One IMAGE Compare

macOS 14+、Apple Silicon 专用的原生图片浏览与 2–8 图对比工具。

## 已实现

- 文件/文件夹批量导入、递归扫描、渐进缩略图、搜索、排序与格式/HDR筛选
- 任意选择 2–8 张，自适应 1×2、2×2、2×3、2×4 对比布局
- 单图查看、同步缩放/平移、受边界约束的拖动、双击复位、滚轮平移与 Command/Option+滚轮缩放；基准图、Vision 平移自动对齐与重置
- 缩略图支持 Shift 范围选择；Return 进入多图对比；B 键切换 HDR/SDR
- JPEG、HEIC/HEIF、PNG、TIFF、DNG、AVIF、ProRAW，以及 macOS 支持的相机 RAW
- 默认 HDR/EDR 显示层与 SDR 基础图（不应用 Gain Map）全局切换；SDR 使用 ImageIO 原生解码请求，不再叠加手工 Tone Mapping；已解码的 HDR/SDR 预览分别缓存，往返切换不重复解码
- 缩略图模式下上一张/下一张只移动选择并更新检查器，不自动进入大图；进入大图后先显示缩略图占位，再异步解码并缓存 2800px 预览
- HDR/SDR 使用同一组 Tab 点击切换；缩略图模式切换 Tab 不触发全图解码
- RGB、单通道、亮度直方图；统一在线性相对亮度域统计，SDR 白点左区 + HDR 0–4 EV 右区，曲线不再按元数据二次缩放；面板可独立展开/收起
- Gain Map、照片信息与效果分析 Tab；效果分析将 HDR 源数据、内容重建效果和当前屏幕能力分开，HDR 指标优先使用 Base Image + 原始 Gain Map + ISO 21496-1 参数重建后统计，并提供 Gain Map 实际增益分布、有效动态范围、P01/P05/P50/P95/P99、白点/近黑占比、细节能量、饱和度、色相、RGB 平衡和扩展亮度像素等客观数据
- 矢量示波器式肤色指示器：显示全色彩分布、候选肤色分布、19°肤色方向线及候选肤色偏离度；候选肤色使用 HSV + YCbCr 双重条件，不把肤色线当作硬阈值
- EXIF、Base/Alternate 分层色彩空间、Base/HDR 传递函数、HDR 类型、Gain Map、PQ/HLG、多证据置信度；Gain Map 信息面板优先展示 ISO 21496-1 / Apple HDR Gain Map 的屏幕与辅助图参数，并可切换至原照片信息
- 元数据 CSV、直方图 bin CSV、PDF 技术报告和可继续编辑的项目文件
- 默认 50% 灰界面，另有深色和浅色外观

## 构建 DMG

需要 macOS 14+、Apple Silicon 和 Xcode 15.3 或更高版本：

```bash
chmod +x scripts/build_dmg.sh
./scripts/build_dmg.sh
```

产物位于 `dist/One-IMAGE-Compare-1.0.0-arm64.dmg`。

也可以把工程推送至 GitHub 后手动运行已附带的 `Build macOS DMG` 工作流，
其 macOS 14 runner 会生成同名 DMG artifact。

当前脚本生成 ad-hoc 签名，适合本机或内部安装。公开分发需要 Apple Developer ID，
将脚本中的签名替换为 Developer ID Application，并执行 notarization。

## 技术口径

- HDR 识别不以“10 bit”或“P3”单独下结论，优先读取 Gain Map、PQ/HLG 和色彩描述。
- Gain Map 照片分别展示主图/Base 色彩空间、HDR Alternate 色彩空间与各自传递函数；Alternate 不再统一硬编码为 BT.2100。对 Display P3 + PQ、BT.2100 PQ、PQ Adaptive Gain Curve、444f/420f 等实际文件描述按辅助数据逐文件解析。
- Gain Map 照片的 SDR 视图直接请求 ImageIO 解码基础图，不应用 Gain Map；HDR 预览请求系统应用 Gain Map/EDR，但 HDR 效果分析会单独读取 Base Image 与原始辅助 Gain Map，按 ISO 21496-1 受控重建后统计，不把系统预览或当前屏幕输出冒充为图片自身 HDR 指标。仍保留 Gain Map 元数据用于信息展示，不会删除原文件辅助数据。
- 当 ImageIO 只公开 Gain Map 的描述和元数据、未直接公开 kCGImageAuxiliaryDataInfoData 时，使用 Core Image 的 auxiliaryHDRGainMap 辅助图接口读取原始单色 Gain Map；这覆盖 444f 与 420f 等双平面格式，仍属于源辅助图分析，不回退到系统 HDR 预览。
- 当前屏幕的 Gain Map Weight (W) 是按屏幕 headroom 与文件中的 Base/Alternate HDR Headroom 计算的显示权重，不是照片中固化的常数。
- 缺乏可靠绝对亮度元数据时不显示伪造 nit 值。
- RAW 使用系统 Core Image RAW 解码；实际兼容范围随 macOS 相机 RAW 支持变化。
- 自动对齐只保存视图变换，不修改原图。

## V1 边界

当前自动对齐实现平移配准；旋转、尺度和轻微透视配准已预留数据结构，但需要后续
使用真实样张在 macOS 上验证后再启用。HDR/EDR 是否真正达到屏幕峰值也取决于图片
元数据、当前显示器和 macOS 的 EDR 状态。应用在信息不足时只给出相对判断，不伪造
绝对亮度。
