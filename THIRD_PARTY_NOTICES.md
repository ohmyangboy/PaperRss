# PaperRss 第三方软件声明 / Third-Party Software Notices

**更新日期 / Updated:** 2026-08-27

PaperRss 本身依据 [GNU General Public License v3.0](LICENSE) 发布。以下组件由各自权利人依据各自许可证提供；PaperRss 的 GPL-3.0 不会替代、限制或重新许可这些独立组件的许可证。第三方名称和商标仅用于识别相关组件，不表示其对 PaperRss 的背书。

PaperRss itself is distributed under the [GNU General Public License v3.0](LICENSE). The components below are provided by their respective rightsholders under their own licenses. PaperRss's GPL-3.0 does not replace, restrict, or relicense those independent licenses. Third-party names and marks are used only to identify the relevant components and do not imply endorsement of PaperRss.

## Bundled and linked components

| Component | Version | Copyright / project | License | Source and license |
| --- | --- | --- | --- | --- |
| GRDB.swift | 7.11.1 | Copyright © 2015–2025 Gwendal Roué | MIT | [Source](https://github.com/groue/GRDB.swift/tree/v7.11.1) · [License](https://github.com/groue/GRDB.swift/blob/v7.11.1/LICENSE) |
| Sparkle | 2.9.6 | Andy Matuschak, Elgato Systems GmbH, Kornel Lesiński, Mayur Pawashe, C.W. Betts, Petroules Corporation, Big Nerd Ranch, and contributors | MIT, with separately identified bundled third-party components | [Source](https://github.com/sparkle-project/Sparkle/tree/2.9.6) · [Complete license notices](https://github.com/sparkle-project/Sparkle/blob/2.9.6/LICENSE) |
| swift-markdown | 0.8.0 | Copyright © 2021 Apple Inc. and the Swift project authors | Apache License 2.0 | [Source](https://github.com/swiftlang/swift-markdown/tree/0.8.0) · [License](https://github.com/swiftlang/swift-markdown/blob/0.8.0/LICENSE.txt) · [NOTICE](https://github.com/swiftlang/swift-markdown/blob/0.8.0/NOTICE.txt) |
| swift-cmark | 0.8.0 | John MacFarlane and other identified contributors | BSD-style licenses and separately identified component licenses | [Source](https://github.com/swiftlang/swift-cmark/tree/0.8.0) · [Complete notices](https://github.com/swiftlang/swift-cmark/blob/0.8.0/COPYING) |
| MathJax `tex-mml-svg-mathjax-tex` runtime | 4.1.2 | MathJax project contributors | Apache License 2.0 | [Bundled component record](PaperRss/Resources/MathJax/README.md) · [Bundled license](PaperRss/Resources/MathJax/LICENSE) · [Project](https://github.com/mathjax/MathJax) |

## Required attribution text retained by this distribution

### GRDB.swift — MIT License

> Copyright (C) 2015-2025 Gwendal Roué
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### swift-markdown — NOTICE

> The Swift Markdown Project  
> Copyright (c) 2021 Apple Inc. and the Swift project authors  
> Licensed under the Apache License, Version 2.0.  
> This product contains a derivation of the cmark-gfm project available through swift-cmark.

The complete Apache License 2.0 text is retained in [PaperRss/Resources/MathJax/LICENSE](PaperRss/Resources/MathJax/LICENSE). Complete upstream notices for Sparkle and swift-cmark are linked in the table because they include multiple separately attributed source files. Release packaging must retain the licenses embedded by those packages and the bundled MathJax license; this document must be distributed with source releases and remain publicly accessible with binary releases.

Apache License 2.0 的完整文本保存在 [PaperRss/Resources/MathJax/LICENSE](PaperRss/Resources/MathJax/LICENSE)。Sparkle 与 swift-cmark 的上游许可证包含多个独立文件的署名，完整文本见表格中的固定版本链接。发布打包时必须保留依赖自身携带的许可证和 MathJax 许可证；本说明应随源码发布，并在二进制发布时保持公开可访问。

## Website fonts and external services

The project website requests Inter, JetBrains Mono, and Noto Serif SC from Google Fonts. Those fonts and the Google Fonts service are governed by their respective licenses and terms. The website also links to GitHub and PayPal; those services are not bundled with PaperRss and operate under their own terms and privacy policies.

项目官网会向 Google Fonts 请求 Inter、JetBrains Mono 和 Noto Serif SC；字体及服务分别适用其自身许可证与条款。官网也链接至 GitHub 和 PayPal；这些服务没有被打包进 PaperRss，并按各自条款和隐私政策运行。

If a bundled dependency, version, or license changes, update this file before release. Questions about attribution may be sent to [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com).

如果打包依赖、版本或许可证发生变化，应在发布前更新本文件。署名相关问题可联系 [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com)。

