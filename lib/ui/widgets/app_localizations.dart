// 弹窗输入框的中文本地化兜底。
//
// 背景：MiuixOverlayDialog 的内容挂在 MaterialApp 之外的 popup host 上，
// 祖先链里没有 Localizations。而 flutter/material 的 TextField 在 build
// 期强制要求 MaterialLocalizations（debugCheckHasMaterialLocalizations），
// 缺失时抛异常 → 被 RenderErrorBox 替换 → 无高度约束下变成 100000px 的
// 灰色大块，把整个弹窗撑爆（v2.2.9 用户截图反馈）。
//
// 标准解法是引入 flutter_localizations 包，但当前环境无法访问 pub.dev，
// 且本 App 全中文 UI，故自包含实现：继承 material 的英文默认实现，
// 只覆写用户可见的编辑操作文案，其余（日期格式等）保持默认。
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';

/// 中文 [MaterialLocalizations]：继承英文默认，覆写编辑/操作类文案。
class AppZhMaterialLocalizations extends DefaultMaterialLocalizations {
  const AppZhMaterialLocalizations();

  // ---- 文本编辑（TextField 长按选择菜单用）----
  @override
  String get copyButtonLabel => '复制';

  @override
  String get cutButtonLabel => '剪切';

  @override
  String get pasteButtonLabel => '粘贴';

  @override
  String get selectAllButtonLabel => '全选';

  @override
  String get lookUpButtonLabel => '查询';

  @override
  String get searchWebButtonLabel => '网页搜索';

  @override
  String get shareButtonLabel => '分享';

  // ---- 通用工具提示 ----
  @override
  String get openAppDrawerTooltip => '打开导航菜单';

  @override
  String get closeButtonLabel => '关闭';

  @override
  String get moreButtonTooltip => '更多';

  @override
  String get searchFieldLabel => '搜索';

  @override
  String get clearButtonTooltip => '清空';

  @override
  String get backButtonTooltip => '返回';

  @override
  String get closeButtonTooltip => '关闭';

  @override
  String get deleteButtonTooltip => '删除';

  @override
  String get nextMonthTooltip => '下个月';

  @override
  String get previousMonthTooltip => '上个月';

  @override
  String get drawerLabel => '导航菜单';

  @override
  String get popupMenuLabel => '弹出菜单';

  @override
  String get dialogLabel => '对话框';

  @override
  String get alertDialogLabel => '提示';

  @override
  String get modalBarrierDismissLabel => '关闭';

  @override
  String get scrimLabel => '遮罩';

  @override
  String scrimOnTapHint(String modalRouteContentName) => '点按空白处关闭';

  // ---- 计数 ----
  @override
  String remainingTextFieldCharacterCount(int remaining) {
    return switch (remaining) {
      0 => '已到达字数上限',
      1 => '还可输入 1 个字符',
      _ => '还可输入 $remaining 个字符',
    };
  }

  @override
  String selectedRowCountTitle(int selectedRowCount) => '已选择 $selectedRowCount 项';
}

/// 同步加载 [AppZhMaterialLocalizations] 的委托（所有 locale 均声明支持，
/// 保证 `_loadAll` 不会因 isSupported 过滤而漏掉它）。
class AppZhMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const AppZhMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      SynchronousFuture<MaterialLocalizations>(
          const AppZhMaterialLocalizations());

  @override
  bool shouldReload(AppZhMaterialLocalizationsDelegate old) => false;
}

/// [Localizations] 组件断言要求委托列表里必须有一个
/// `LocalizationsDelegate<WidgetsLocalizations>`，这里用英文默认实现补齐
/// （仅 textDirection 等结构性信息，无用户可见文案）。
class AppWidgetsLocalizationsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const AppWidgetsLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      SynchronousFuture<WidgetsLocalizations>(
          const DefaultWidgetsLocalizations());

  @override
  bool shouldReload(AppWidgetsLocalizationsDelegate old) => false;
}
