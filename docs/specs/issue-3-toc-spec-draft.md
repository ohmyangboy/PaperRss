# 草案：长文章目录导航功能 (Issue #3)

- **原始 Issue**: [#3 希望能够加入目录的功能](https://github.com/ohmyangboy/PaperRss/issues/3)
- **提交者**: @cheemskc
- **状态**: 待评估 / 草案阶段
- **类型**: UI/UX 功能增强 (Feature Request)

---

## 1. 需求背景与目标

长文章或技术博客在阅读时缺乏目录大纲（Table of Contents），用户跳转查看特定章节成本较高。用户期望提供类似 ChatGPT / Obsidian 侧边栏的**文章目录导航条（TOC Bar）**。

### 核心目标
* 自动解析当前阅读文章中的标题标签（`<h1>` ~ `<h6>`）。
* 在阅读器侧边栏或悬浮按钮中展示结构化目录树。
* 点击目录项流畅平滑滚动跳转至对应章节。
* 阅读进度随页面滚动实时高亮当前所在章节。

---

## 2. 技术实现方案

```mermaid
graph TD
    A[文章 HTML 内容加载] --> B[JS / DOM 解析器]
    B --> C[提取 Heading 标签 (h1-h6) 并注入 id 锚点]
    C --> D[构建 TOC 目录数据结构]
    D --> E[渲染 UI 侧边栏目录条]
    E --> F[监听 Scroll 事件更新高亮及点击跳转]
```

### 1. 目录提取与解析（HTML AST / DOM Parser）
在 Web 视图或 HTML 渲染层加载完成文章内容后，提取所有标题节点：
```javascript
// 示例逻辑
const headings = Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6')).map((el, index) => {
  if (!el.id) el.id = `toc-heading-${index}`;
  return {
    id: el.id,
    text: el.innerText,
    level: parseInt(el.tagName.replace('H', ''), 10),
    top: el.offsetTop
  };
});
```

### 2. UI/UX 布局设计
- **大屏/Desktop 视图**: 右侧可收起的侧边栏（Inspector / Outline Panel）。
- **小屏/Mobile 视图**: 底部浮动按钮，点击弹出 Sheet 或 Popover 抽屉展示目录。

---

## 3. 待解决问题 (Open Questions)

- [ ] 对于没有使用 `<h1>-<h6>` 标签而是纯 CSS 加粗的非标准 HTML 内容，如何退化处理？
- [ ] 目录栏默认是折叠还是展开状态？用户偏好设置持久化。
