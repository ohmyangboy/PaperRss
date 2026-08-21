# 每周想法与待办

## drafts

1. 🚧 ​**Sparkle 自动更新系统迁移**  

   目标：采用生产级 macOS 自动更新方案，替代当前 Release 检测更新。

   - [ ] 集成 Sparkle 2
   - [ ] 移除旧 Release Checker
   - [ ] 实现 SparkleUpdater 管理模块
   - [ ] 增加 Settings 中更新入口
   - [ ] 配置 appcast.xml
   - [ ] 配置 Sparkle EdDSA signing
   - [ ] 测试后台下载更新
   - [ ] 测试 Restart to Update 流程
   - [ ] 验证更新后用户数据保持
1. **双译翻译展示方式**

   - 增加可选方式：左右对照、上下对照、直接替换原文。
1. **字体设置**

   - 支持阅读视图字体自定义。
1. **支持公众号RSS。**

   - 待调研

## bugfix

1. **应用全屏标题栏重绘异常**
2. **feed头像闪烁**
3. **lilian weng 博客，markdown渲染问题**

   - 排查底层markdown引擎，核查学术公式、图标的兼容性
   - 少数派，blog图片渲染问题，排版问题
4. **批量导入导致应用崩溃，待排查**

   - 现象：超过 > 300 个订阅 导入崩溃
   - 初步判断：导入过程sql操作并发控制没有做到位，或者导入结束后读取全文时内存爆了