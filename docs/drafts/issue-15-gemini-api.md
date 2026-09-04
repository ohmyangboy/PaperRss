# PaperRss Gemini、多供应商、功能模型路由与 AI 多任务

- **Status**: accepted
- **Issues**: https://github.com/ohmyangboy/PaperRss/issues/15, https://github.com/ohmyangboy/PaperRss/issues/16, https://github.com/ohmyangboy/PaperRss/issues/20

## 问题

PaperRss 需要完整支持 Google Gemini 官方 OpenAI-compatible 接口、保存多个 AI 供应商及模型，并允许摘要、双语翻译和三种划词能力分别选择模型。当前实现把供应商、模型和功能运行时配置混在一起，以单例请求状态限制并发，同时用当前 Provider 指纹过滤用户已生成的产物。这会造成切文串台、无法并行处理多篇文章，以及切换供应商后摘要或译文“消失”。

## 领域语义

- Provider 只描述连接能力和已配置模型目录，不再表达“当前供应商”或“当前模型”。内置 OpenAI、DeepSeek、Gemini 和自定义 OpenAI-compatible Provider 均可保存多个模型。
- 五个功能分别配置开关与 `Provider / Model`：文章摘要、双语翻译、划词翻译、划词解释、划词提问。模型选择引用 Provider 中的模型，不复制连接信息。
- AI 请求入队时冻结不可变执行上下文，包括功能、Provider、模型、功能级思考深度、目标语言、Prompt、Base URL 和 API Key。Key 不进入指纹、日志、同步或产物。
- Provider、模型或参数变化只影响后续请求，不改变、隐藏或重新解释已经生成的用户可见产物。执行指纹只用于内部缓存隔离和来源审计。

## 设置模型与迁移

`AISettings` schema 升级到 v5：

```swift
enum AIFeatureKind: String, Codable, CaseIterable {
    case summary, bilingualTranslation, selectionTranslation
    case selectionExplanation, selectionAsk
}

struct AIModelReference: Codable, Hashable {
    let providerID: String
    let modelID: String
}

struct AIFeatureConfiguration: Codable, Hashable {
    var isEnabled: Bool
    var model: AIModelReference?
    var reasoningMode: String
}
```

- `AIModelProfile` 只保存用户明确加入的模型 ID、显示名和来源；`AIProviderProfile` 保存 Provider kind、启用状态、名称、说明、Base URL、本地 HTTP 策略和模型列表。
- 思考深度按功能保存，只提供自动、低、中、高；设置 UI 不暴露 temperature。
- v3/v4→v5 首次迁移把旧当前 Provider/模型绑定到全部五个功能，并把旧推理强度迁入功能。旧版自动拉取但未经确认的远端模型不进入已配置目录，只保留手动、当前或被功能引用的模型。
- 新安装时 DeepSeek 排在第一位，五个功能默认开启并绑定 `DeepSeek / deepseek-v4-flash`，思考深度默认自动；“打开文章时自动生成摘要”仍默认关闭。
- Provider 可以停用；停用不会删除连接或功能绑定，但其模型不出现在功能选择列表，也不能用于新请求。
- 删除被引用的模型或自定义 Provider 前列出受影响功能；保存删除后自动改绑首个可用模型。完全没有模型时关闭对应功能并显示配置警告。
- 旧 `LLMConfiguration + API Key` 兼容投影始终跟随“文章摘要”绑定，配置和密钥必须成对更新；摘要绑定无密钥或无法完整表示时保留上一组完整兼容值。
- Gemini 使用 `https://generativelanguage.googleapis.com/v1beta/openai`、Bearer Key、`/chat/completions`、`/models` 与 SSE。Gemini 3 省略 temperature；功能页只提供自动/低/中/高思考深度。

## 运行时深模块

`ArticleAIWorkspace` 是应用级模块，内部 actor 负责队列、去重、取消、持久化和事件身份。`AppStore` 只解析配置并转发调用：

```swift
func submit(_ request: ArticleAIRequest) throws -> AIJobID
func perform(
    _ request: SelectionAIRequest,
    in generation: AIDocumentGeneration
) async throws -> SelectionAIResponse
func cancel(_ scope: AIJobCancellationScope)
func projection(for entryID: String) -> ArticleAIProjection
```

- 摘要和已请求的双语段落批次共享最多 6 个后台运行槽，第 7 个及之后按 FIFO 排队。划词翻译、解释和提问使用独立前台通道，不被后台池阻塞。
- 后台作业按 `entryID + kind` 去重。摘要“重新生成”替换该文章的旧作业；双语新段落 ID 合并进该文章已有作业。
- 切文不取消摘要，也不取消已经提交的双语段落；离开后不再自动追加新可见段落。明确关闭某文章的双语模式时，取消其排队与运行中翻译。
- 划词请求绑定 `entryID + document generation + requestID`，切文立即取消。所有增量、完成、错误和清理事件在投影与落库前再次校验身份，旧事件不得覆盖新请求。

## 用户可见产物

### 文章摘要

- 每篇文章只有一个“当前摘要”。读取当前摘要只按文章查询最新完整、未删除记录，不按当前 Provider、模型或执行指纹过滤。
- 普通“生成摘要”在已有摘要时不发起付费请求；“重新生成”使用摘要功能当前绑定模型。
- 重新生成期间可预览新流式内容。只有完整成功后才事务性替换当前摘要；失败或取消保留旧摘要。
- 正文 hash 改变后仍显示旧摘要并标记“正文已更新”，不自动付费重生成。
- 数据迁移按完成时间保留最新完整摘要，其余摘要写入现有 `isDeleted` 墓碑。正文 `1248257672826666390` 因此保留 17:03 完成的 Gemini 摘要为当前版本。

### 双语翻译与划词产物

- 双语译文按 `entryID + 正文 hash + 目标语言` 选取当前产物，忽略 Provider/model。后续新增段落使用双语功能当前绑定模型，并在段落中保存可选来源；旧段落继续显示。
- 划词解释和提问的历史标注不按当前执行指纹过滤；正文 hash 和锚点校验继续生效。
- 翻译记忆等内部缓存继续使用 `subject + artifact kind + input digest + versioned execution fingerprint` 严格隔离。

## 设置界面

- “AI 功能”使用靠左对齐的“功能配置 / 供应商与模型”分段切换。
- 功能页使用内容驱动高度的响应式能力卡片：宽窗口双列、窄窗口单列，不为卡片保留无意义的底部空白。每张卡片显示语义图标、标题、说明、开关、按 Provider 分组的模型菜单和功能级思考深度；文章摘要与双语翻译归入“文章能力”，三种划词操作归入“划词能力”。
- 摘要行另保留“打开文章时自动生成”；翻译目标语言独立成组，自定义摘要提示词归入“个性化”。
- Provider 页采用主从布局：左侧是紧凑供应商列表，显示官方品牌图标、名称、模型数量、启用开关和选中态；右侧保持当前供应商的完整详情，分为基础连接、模型管理和保存操作。模型直接以列表展示，可测试或删除；左侧底部提供“添加供应商”。停用 Provider 后其模型从功能菜单中移除。
- 内置名称和 Base URL 固定；自定义 Provider 可编辑。API 格式只展示真实支持的 OpenAI-compatible Chat Completions。
- 每个模型行可测试和删除；模型 ID 不原地修改，思考深度不在模型详情中配置。
- “添加模型”使用可搜索、多选 sheet。远端目录先进入候选区，用户点击“添加 N 个”后才写入 Provider 草稿；保留手动模型 ID。
- Provider 顶部“保存更改”统一提交连接与模型草稿。切换脏草稿提供保存、丢弃、取消；获取和测试继续绑定 Provider ID、草稿 revision 与 operation ID，迟到结果不得串写。

## 验收条件

1. 六个摘要/双语作业并行，第七个 FIFO 排队；划词请求不受后台池阻塞。
2. A、B 可同时摘要和翻译相同 `p0`，切文、返回和迟到回调均不得串台；切文后只完成已提交段落。
3. 请求运行中切换功能模型，旧请求使用冻结配置；后续请求使用新绑定。
4. Provider/model 切换不隐藏摘要、双语或划词标注。
5. 多个摘要只展示最新完整版本；重新生成成功原子替换，失败保留旧版；正文变化显示过期状态。
6. v2/v3/v4→v5 迁移幂等；功能默认绑定、Provider 启用过滤、旧远端目录清理、模型/Provider 删除回退和兼容密钥对均正确，清空密钥不会复活。
7. 模型远端目录必须经确认才进入草稿；迟到拉取和测试结果不能污染其他 Provider。
8. 功能级思考深度实际进入请求，adapter 只施加协议能力限制；设置 UI 不暴露 temperature。

## 验证矩阵

- 从公开 interface 加入失败回归测试，再按 settings 迁移、产物稳定性、后台队列、阅读器接线和设置 UI 的纵向切片实现。
- 执行 `./scripts/verify.sh --core`、`./scripts/verify.sh --feature`、`./scripts/verify.sh --web`、macOS `xcodebuild` 与 `git -c core.fsmonitor=false diff --check`。
- 使用隔离配置和本地延迟 OpenAI-compatible mock 服务启动真实 macOS App，操作 Provider CRUD、模型多选添加/测试、功能路由、重启持久化、七作业排队和 A/B 切文。
- 通过 `./scripts/dev.sh` 启动真实 macOS App，实际观察两页设置、菜单、草稿确认、摘要过期提示与并发状态。
- 真实 Gemini 摘要和翻译由维护者使用自己的 Key 验证；确认前保持“真实 Gemini E2E 待人工验证”。

## 不在范围内

- 发布、提交、推送和关闭 Issue。
- 新增 iOS 产品功能；共享桥接代码只维持同等的请求身份和产物语义。
