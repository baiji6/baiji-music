# 白姬音乐 —— HarmonyOS（鸿蒙）工程说明

## 目录结构

```
ohos/
├── AppScope/                # 应用级配置（bundleName / 图标 / 名称）
├── entry/                   # 应用主模块（stage 模型）
│   ├── build-profile.json5  # 模块构建配置（release 时引用混淆规则）
│   ├── obfuscation-rules.txt# 方舟混淆规则
│   └── src/main/
│       ├── module.json5     # 模块清单
│       ├── ets/             # ArkTS 源码（EntryAbility + 启动页）
│       └── resources/       # 资源（字符串 / 颜色 / 页面路由 / 图标）
├── hvigor/                  # hvigor 构建配置
├── build-profile.json5      # 工程构建配置（SDK 版本 / 签名 / 构建模式）
└── oh-package.json5         # ohpm 依赖清单
```

## 构建方式

### 方式一：DevEco Studio（推荐）
1. 用 DevEco Studio（5.0.0+，API 12）打开本 `ohos/` 目录。
2. File → Sync and Refresh Project，等待 ohpm 依赖同步。
3. 选择 `release` 构建变体，Build → Build Hap(s) / APP(s)。
4. release 构建自动按 `entry/obfuscation-rules.txt` 执行方舟混淆。

### 方式二：命令行
```bash
cd ohos
hvigorw assembleHap --mode module -p product=default -p buildMode=release
```
（需 DevEco Studio 自带的环境变量：`DEVECO_SDK_HOME` / `hvigorw` 已在工程中）

## 混淆说明（release 自动生效）
- `entry/build-profile.json5` → `buildOptionSet.release.arkOptions.obfuscation.ruleOptions`
  声明启用 `./obfuscation-rules.txt`，开混淆的能力包括：
  - 属性混淆（property）
  - 顶层作用域混淆（toplevel）
  - 文件名混淆（filename）
- 保留规则：入口 Ability 的全局名与属性（系统按 manifest 反射调用，不可混淆）。
- 接入 Flutter 引擎桥接类后，在 `obfuscation-rules.txt` 按需细化 keep，避免破坏 JSBridge 签名。

## 壳工程说明
本目录是**原生鸿蒙壳工程**：包含完整可构建的 stage 模型入口与启动页，
运行时展示与 Flutter 侧一致的主题视觉。
业务层（搜索 / 播放 / 下载 / QQ 音乐 / 网易云）实现在 `../lib/`（Flutter/Dart 侧），
通过 flutter-ohos 引擎（OpenHarmony Flutter 发行版）接入本壳的 Flutter 容器后运行，
详见根目录 README「鸿蒙适配」章节。

## 签名
正式发布需在 `build-profile.json5` 的 `signingConfigs` 中配置签名材料
（.p12 / .cer / .p7b，DevEco Studio 自动签名即可）。