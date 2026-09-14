(() => {
  if ('scrollRestoration' in history) {
    history.scrollRestoration = 'manual';
  }

  if (window.location.hash) {
    history.replaceState(null, '', window.location.pathname + window.location.search);
  }
  window.scrollTo(0, 0);
  window.addEventListener('load', () => {
    window.scrollTo(0, 0);
  });

  const reduceMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');

  function easeInOutQuart(t) {
    return t < 0.5 ? 8 * t * t * t * t : 1 - Math.pow(-2 * t + 2, 4) / 2;
  }

  function easeInOutCubic(t) {
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  }

  function initStageParallax() {
    const heroContent = document.querySelector('.hero-content') || document.querySelector('.hero');
    const stageSection = document.getElementById('stage-showcase');

    const baseCard = stageSection ? stageSection.querySelector('.stage-card-base') || stageSection.querySelector('.stage-card-1') : null;
    const stackCards = stageSection
      ? Array.from(stageSection.querySelectorAll('.stage-card')).filter((card) => card !== baseCard)
      : [];

    const baseScrim = baseCard ? baseCard.querySelector('.stage-card-scrim') : null;

    let stageTop = 0;
    let stageHeight = 0;
    let viewportHeight = window.innerHeight;
    let isMobile = false;

    function measureLayout() {
      viewportHeight = window.innerHeight;
      isMobile = reduceMotionQuery.matches || window.innerWidth <= 1024;
      const scrollY = window.pageYOffset || document.documentElement.scrollTop || 0;

      if (stageSection) {
        const rect = stageSection.getBoundingClientRect();
        stageTop = rect.top + scrollY;
        stageHeight = rect.height;
      }
    }

    let targetStageProgress = 0;
    let currentStageProgress = 0;

    let targetHeroProgress = 0;
    let currentHeroProgress = 0;

    let isLoopRunning = false;

    function calculateTargets() {
      const scrollY = window.pageYOffset || document.documentElement.scrollTop || 0;

      // 1. Hero progress
      const heroThreshold = Math.min(viewportHeight * 0.75, 540);
      targetHeroProgress = Math.max(0, Math.min(1, scrollY / heroThreshold));

      // 2. Stage showcase progress
      if (stageSection) {
        const totalScrollable = stageHeight - viewportHeight;
        if (totalScrollable > 0) {
          const scrolled = scrollY - stageTop;
          targetStageProgress = Math.max(0, Math.min(1, scrolled / totalScrollable));
        } else {
          targetStageProgress = 0;
        }
      }
    }

    function renderFrame() {
      const lerpFactor = 0.14;

      const heroDelta = targetHeroProgress - currentHeroProgress;
      const stageDelta = targetStageProgress - currentStageProgress;

      if (Math.abs(heroDelta) > 0.0003) {
        currentHeroProgress += heroDelta * lerpFactor;
      } else {
        currentHeroProgress = targetHeroProgress;
      }

      if (Math.abs(stageDelta) > 0.0003) {
        currentStageProgress += stageDelta * lerpFactor;
      } else {
        currentStageProgress = targetStageProgress;
      }

      // --- 1. Hero Parallax ---
      if (heroContent) {
        const hMotionEase = easeInOutQuart(currentHeroProgress);
        const hBlurEase = easeInOutCubic(currentHeroProgress);

        const hScale = (1 - 0.035 * hMotionEase).toFixed(4);
        const hBlur = (4.0 * hBlurEase).toFixed(1);
        const hOpacity = (1 - 0.55 * hMotionEase).toFixed(2);
        const hTranslateY = -(hMotionEase * 28).toFixed(1);

        heroContent.style.transform = `translate3d(0, ${hTranslateY}px, 0) scale(${hScale})`;
        heroContent.style.filter = `blur(${hBlur}px)`;
        heroContent.style.opacity = hOpacity;
      }

      // --- 2. Stage Showcase Parallax (N-Card Stacking Overlap) ---
      if (baseCard && stackCards.length) {
        const phaseCount = stackCards.length;
        const leadIn = 0.03;
        const leadOut = 0.97;
        const phaseSpan = (leadOut - leadIn) / phaseCount;

        // One eased progress value per transition: card N glides over card N-1
        const eases = [];
        for (let i = 0; i < phaseCount; i += 1) {
          const phaseStart = leadIn + i * phaseSpan;
          const phaseEnd = phaseStart + phaseSpan * 0.85;
          let p = 0;
          if (currentStageProgress > phaseStart) {
            p = Math.min(1, (currentStageProgress - phaseStart) / (phaseEnd - phaseStart));
          }
          eases.push(easeInOutQuart(p));
        }

        // Base card: subtle scale + scrim blur while the first stacked card glides over it
        const baseEase = eases[0];
        const baseScale = (1 - 0.04 * baseEase).toFixed(4);
        baseCard.style.transform = `translate3d(0, 0, 0) scale(${baseScale})`;
        if (baseScrim) {
          baseScrim.style.opacity = baseEase.toFixed(3);
        }

        // Stacked cards: each starts 115% lower than the card above and rises 115% per phase
        stackCards.forEach((card, index) => {
          let remaining = 0;
          for (let j = 0; j <= index; j += 1) {
            remaining += 1 - eases[j];
          }
          const translateY = (remaining * 115).toFixed(2);

          const coverEase = eases[index + 1];
          const scale = coverEase === undefined ? 1 : 1 - 0.04 * coverEase;
          card.style.transform = `translate3d(0, ${translateY}%, 0) scale(${scale.toFixed(4)})`;

          const scrim = card.querySelector('.stage-card-scrim');
          if (scrim && coverEase !== undefined) {
            scrim.style.opacity = coverEase.toFixed(3);
          }
        });
      }

      if (
        Math.abs(targetHeroProgress - currentHeroProgress) > 0.0003 ||
        Math.abs(targetStageProgress - currentStageProgress) > 0.0003
      ) {
        window.requestAnimationFrame(renderFrame);
      } else {
        isLoopRunning = false;
      }
    }

    function requestRender() {
      if (isMobile) {
        if (heroContent) {
          heroContent.style.transform = '';
          heroContent.style.filter = '';
          heroContent.style.opacity = '';
        }
        if (baseCard) {
          baseCard.style.transform = '';
          baseCard.style.filter = '';
        }
        stackCards.forEach((card) => {
          card.style.transform = '';
          card.style.filter = '';
          const scrim = card.querySelector('.stage-card-scrim');
          if (scrim) scrim.style.opacity = '';
        });
        if (baseScrim) baseScrim.style.opacity = '';
        return;
      }

      calculateTargets();

      if (!isLoopRunning) {
        isLoopRunning = true;
        window.requestAnimationFrame(renderFrame);
      }
    }

    function onResize() {
      measureLayout();
      requestRender();
    }

    window.addEventListener('scroll', requestRender, { passive: true });
    window.addEventListener('resize', onResize, { passive: true });
    reduceMotionQuery.addEventListener('change', onResize);

    measureLayout();
    requestRender();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initStageParallax);
  } else {
    initStageParallax();
  }
})();
