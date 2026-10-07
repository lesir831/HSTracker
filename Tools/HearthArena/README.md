# HearthArena 竞技场基础评分

来源：[HearthArena 简体中文选牌参考](https://www.heartharena.com/zh-cn/tierlist)。

在设置 → 竞技场中，可独立开关「显示 HearthArena 选牌评分」，默认开启。
该开关不依赖 Arenasmith、HSReplay 订阅或试用状态。选牌时每张卡下方显示
HearthArena 来源、原始分数和「基础评分」标签；与 Arenasmith 同时显示时向下错开。
悬停展开 Arenasmith 关联卡牌面板时暂时隐藏，避免遮住详情，移开后恢复。
覆盖层不接收鼠标点击，不会代替玩家选牌。

## 评分含义与匹配

- 只读取公开网页的基础评分；不调用 HearthArena 的私有选牌接口。
- 根据当前英雄职业选择网页分区，再以 `data-card-image` 中的卡牌 ID 精确匹配。
  卡名、语言和卡图本身不参与匹配；不会下载图片或运行网页脚本。
- 不压缩到 Arenasmith 的评分范围，不将基础分描述为胜率或牌组协同评分。
  评分保持原值，包括 0、超过 100 的数值和小数。
- 不从中立表或其他职业借用缺失评分，也不凭名称或卡牌 ID 前缀猜测重印牌。
  未收录时显示「该职业暂无评分」，网页不可用时显示「评分暂不可用」。
- 英雄／英雄技能选择不显示单卡评分。双职业缺少网站对应的联合评分时，明确
  标记「暂无双职业评分」，不自行混合两个职业的分数。
- 传说组合显示「仅主牌评分」，不计算或暗示整个组合的得分。
- 普通竞技场及地下竞技场的选牌／重选牌均可展示这个公开基础分；没有额外的
  地下竞技场、牌组协同、弃牌或重选牌修正。
- 此数据独立于 Arenasmith 的成绩记录和 HSReplay 上传字段。

## 获取与失效

`HearthArenaTierList` 使用已有依赖树中的 Kanna 5.2.7，通过 DOM 提取职业、
卡牌 ID 和分数；现在将该已锁定版本显式声明为应用依赖。只接受完整的 11
职业分区、有效 ID 和数值；冲突评分、验证页及不完整页面会拒绝使用。

`HearthArenaRatingsService` 只向上述公开 URL 发 GET 请求，不发送账号、牌组
或选牌数据，不保存 Cookie。验证 HTTPS 来源、HTTP 状态、内容类型和大小。
所有职业共用一次请求，多个同时发生的选牌请求合并：

- 成功获取后缓存 24 小时。
- 刷新失败时可使用不超过 7 天的旧缓存，界面明确标注「缓存」。
- 过期、未来时间或损坏缓存不用于评分；失败后最多每分钟重试一次。
- 缓存位于应用 Caches 下的 `HSTracker/heartharena-tierlist-v1.json`。

独立的 `HearthArenaPickViewModel` 订阅既有 `ArenaStateWatcher`。请求结果带有
当前选牌代次检查；关闭功能、离开竞技场、结束选牌或关闭游戏后，旧请求不能
重新显示结果。重复卡牌以选牌槽位区分。动画、英雄放大和组合详情展开时隐藏。

## 验证

`HSTrackerTests/HearthArenaTests.swift` 覆盖公开网页结构、职业差异、缺失项、
异常页面、缓存与并发、异步过期、重复选项、英雄／双职业、组合和设置恢复。
`Fixtures/heartharena-tierlist.html` 是 2026-09-21 的少量公开网页样本，不是运行时
评分备份。默认测试不联网；可用下列环境变量启用额外验证：

- `TEST_RUNNER_HEARTHARENA_VALIDATION_HTML=/path/to/tierlist.html`：解析完整下载页面。
- `TEST_RUNNER_HEARTHARENA_VALIDATION_LIVE=1`：通过应用实际的 URLSession 服务联网获取。

对 `HearthArenaTests`、`HearthArenaPickTests` 执行 Xcode 测试即可。生产视图的离线
截图输出到 `/tmp/HSTracker-HearthArena-QA/`。网页、单元测试和离线渲染不等同于
在炉石实际选牌界面上的位置验证。

2026-09-21 本地验证：相关测试共 33 项通过，包含完整网页解析和实际 URLSession
联网读取；布局及本地化调整后另复验 6 项通过。最终 Release 构建与深度签名校验
通过。本机 Xcode 27 构建时使用 `MACOSX_DEPLOYMENT_TARGET=12.0` 覆盖，工程中的
部署目标未改动。尚未在炉石实际选牌界面验证位置。
