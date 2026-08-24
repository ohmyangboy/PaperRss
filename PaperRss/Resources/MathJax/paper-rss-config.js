(() => {
  if (window.MathJax) return;
  window.MathJax = {
    // The bundled MathJax 4 component initializes accessibility URL prefixes
    // even when their workers are disabled.  Give it a valid local URL so a
    // WKWebView document cannot fall back to the invalid `//sre` default.
    loader: {
      paths: {
        mathjax: 'file:///__paper_rss_mathjax__'
      }
    },
    tex: {
      inlineMath: [['\\(', '\\)'], ['$', '$']],
      displayMath: [['\\[', '\\]'], ['$$', '$$']],
      processEscapes: true,
      processEnvironments: true
    },
    // MathJax 4's default NewCM font loads uncommon ranges (for example
    // calligraphic) as extra JavaScript files.  The original TeX font has no
    // dynamic ranges and is already present in the combined offline bundle.
    output: {
      font: 'mathjax-tex'
    },
    svg: {
      fontCache: 'local'
    },
    options: {
      enableMenu: false,
      // The app intentionally ships one self-contained renderer file, not the
      // separate SRE worker and math-map payloads used by MathJax 4 speech.
      enableSpeech: false,
      enableBraille: false,
      menuOptions: {
        settings: {
          enrich: false,
          speech: false,
          braille: false
        }
      }
    }
  };
})();
