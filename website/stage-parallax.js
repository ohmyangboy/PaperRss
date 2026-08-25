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

    const baseCard = stageSection ? (stageSection.querySelector('.stage-card-base') || stageSection.querySelector('.stage-card-1')) : null;
    const midCard = stageSection ? (stageSection.querySelector('.stage-card-mid') || stageSection.querySelector('.stage-card-2')) : null;
    const overlayCard = stageSection ? (stageSection.querySelector('.stage-card-overlay') || stageSection.querySelector('.stage-card-top') || stageSection.querySelector('.stage-card-3')) : null;

    const baseScrim = baseCard ? baseCard.querySelector('.stage-card-scrim') : null;
    const midScrim = midCard ? midCard.querySelector('.stage-card-scrim') : null;

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

      // --- 2. Stage Showcase Parallax (3-Card Stacking Overlap) ---
      if (baseCard && midCard && overlayCard) {
        // Phase 1: Card 1 -> Card 2 transition (Card 2 glides 115% -> 0%, Card 3 glides 230% -> 115%)
        const p1Start = 0.03;
        const p1End = 0.46;
        let p1 = 0;
        if (currentStageProgress > p1Start) {
          p1 = Math.min(1, (currentStageProgress - p1Start) / (p1End - p1Start));
        }

        // Phase 2: Card 2 -> Card 3 transition (Card 3 glides 115% -> 0%)
        const p2Start = 0.54;
        const p2End = 0.97;
        let p2 = 0;
        if (currentStageProgress > p2Start) {
          p2 = Math.min(1, (currentStageProgress - p2Start) / (p2End - p2Start));
        }

        const m1 = easeInOutQuart(p1);
        const m2 = easeInOutQuart(p2);

        // Card 1: subtle scale + scrim blur during Phase 1
        const scale1 = (1 - 0.04 * m1).toFixed(4);
        baseCard.style.transform = `translate3d(0, 0, 0) scale(${scale1})`;
        if (baseScrim) {
          baseScrim.style.opacity = m1.toFixed(3);
        }

        // Card 2: Starts at 115% and glides to 0% in Phase 1; then scales in Phase 2
        const scale2 = (1 - 0.04 * m2).toFixed(4);
        const translateY2 = ((1 - m1) * 115).toFixed(2);
        midCard.style.transform = `translate3d(0, ${translateY2}%, 0) scale(${scale2})`;
        if (midScrim) {
          midScrim.style.opacity = m2.toFixed(3);
        }

        // Card 3: Starts at 230%, glides to 115% in Phase 1, and glides from 115% to 0% in Phase 2
        const translateY3 = (((1 - m1) + (1 - m2)) * 115).toFixed(2);
        overlayCard.style.transform = `translate3d(0, ${translateY3}%, 0)`;
      } else if (baseCard && overlayCard) {
        const animStart = 0.05;
        const animEnd = 0.85;

        let p = 0;
        if (currentStageProgress > animStart) {
          p = Math.min(1, (currentStageProgress - animStart) / (animEnd - animStart));
        }

        const motionEase = easeInOutQuart(p);
        const scale = (1 - 0.04 * motionEase).toFixed(4);
        baseCard.style.transform = `translate3d(0, 0, 0) scale(${scale})`;

        if (baseScrim) {
          baseScrim.style.opacity = motionEase.toFixed(3);
        }

        const translateY = ((1 - motionEase) * 115).toFixed(2);
        overlayCard.style.transform = `translate3d(0, ${translateY}%, 0)`;
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
        if (midCard) {
          midCard.style.transform = '';
          midCard.style.filter = '';
        }
        if (overlayCard) {
          overlayCard.style.transform = '';
        }
        if (baseScrim) baseScrim.style.opacity = '';
        if (midScrim) midScrim.style.opacity = '';
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
