#!/usr/bin/env python3
"""部署时截取公开赞赏页中的完整名单，不修改源页面或提交仓库。"""
import argparse
from pathlib import Path
from playwright.sync_api import sync_playwright

SOURCE_URL = "https://ohmyangboy.github.io/blog/posts/paperrss-sponsors/"
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / "website/assets/sponsors-preview.png"


def capture(url: str, output: Path) -> None:
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        try:
            page = browser.new_page(
                viewport={"width": 1200, "height": 900},
                device_scale_factor=2,
                color_scheme="light",
                locale="zh-CN",
            )
            page.set_default_timeout(30000)
            response = page.goto(url, wait_until="load", timeout=60000)
            if response is None or not response.ok:
                raise RuntimeError("赞赏页请求失败，取消生成预览")
            table = page.locator("main article table")
            if table.count() != 1:
                raise RuntimeError("赞赏页必须包含唯一名单表格，请检查页面结构")
            table.wait_for(state="visible")
            if table.locator("tbody tr").count() == 0:
                raise RuntimeError("名单没有数据行，取消生成空白预览")
            page.evaluate("document.fonts.ready")
            # 元素截图会包含完整表格，不受浏览器窗口高度限制。
            png = table.screenshot(type="png", animations="disabled", timeout=30000)
            if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                raise RuntimeError("截图不是有效 PNG")
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary = output.with_suffix(".tmp.png")
            temporary.write_bytes(png)
            temporary.replace(output)
            print(f"赞赏预览已生成：{output}（{len(png)} bytes）")
        finally:
            browser.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=SOURCE_URL)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    capture(args.url, args.output)
