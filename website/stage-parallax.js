(() => {
  // 1. Disable browser scroll restoration so refresh always starts at top
  if ('scrollRestoration' in history) {
    history.scrollRestoration = 'manual';
  }

  // 2. Clear hash and force scroll to top on page refresh/load
  if (window.location.hash) {
    history.replaceState(null, '', window.location.pathname + window.location.search);
  }
  window.scrollTo(0, 0);
  window.addEventListener('load', () => {
    window.scrollTo(0, 0);
  });

  const reduceMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');

  // Universal high-grade Ease-In-Out curves (slow start, fluid surge, soft landing)
  function easeInOutQuart(t) {
    return t < 0.5 ? 8 * t * t * t * t : 1 - Math.pow(-2 * t + 2, 4) / 2;
  }

  function easeInOutCubic(t) {
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  }

  function initStageParallax() {
    const heroContent = document.querySelector('.hero-content') || document.querySelector('.hero');
    const stageSection = document.getElementById('stage-showcase');
    const featuresSection = document.getElementById('features');
    const sponsorSection = document.getElementById('sponsor');

    const baseCard = stageSection ? stageSection.querySelector('.stage-card-base') : null;
    const overlayCard = stageSection ? stageSection.querySelector('.stage-card-overlay') : null;
    const baseScrim = stageSection ? stageSection.querySelector('.stage-card-scrim') : null;

    // Cache layout metrics to eliminate forced reflows during scroll
    let stageTop = 0;
    let stageHeight = 0;
    let sponsorTop = 0;
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

      if (sponsorSection) {
        const sRect = sponsorSection.getBoundingClientRect();
        sponsorTop = sRect.top + scrollY;
      }
    }

    // Target vs Current progress for smooth LERP physical interpolation across all sections
    let targetStageProgress = 0;
    let currentStageProgress = 0;

    let targetHeroProgress = 0;
    let currentHeroProgress = 0;

    let targetSponsorProgress = 0;
    let currentSponsorProgress = 0;

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

      // 3. Features -> Sponsor overlapping progress
      if (sponsorSection) {
        const triggerPoint = sponsorTop - viewportHeight * 0.85;
        const triggerRange = Math.min(viewportHeight * 0.8, 550);
        if (scrollY > triggerPoint) {
          targetSponsorProgress = Math.max(0, Math.min(1, (scrollY - triggerPoint) / triggerRange));
        } else {
          targetSponsorProgress = 0;
        }
      }
    }

    function renderFrame() {
      // Smooth LERP (Linear Interpolation) with fluid physical inertia
      const lerpFactor = 0.13;

      const heroDelta = targetHeroProgress - currentHeroProgress;
      const stageDelta = targetStageProgress - currentStageProgress;
      const sponsorDelta = targetSponsorProgress - currentSponsorProgress;

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

      if (Math.abs(sponsorDelta) > 0.0003) {
        currentSponsorProgress += sponsorDelta * lerpFactor;
      } else {
        currentSponsorProgress = targetSponsorProgress;
      }

      // --- 1. Hero Parallax: Ease-In-Out on Motion, Blur, Scale, and Fade ---
      if (heroContent) {
        const hMotionEase = easeInOutQuart(currentHeroProgress);
        const hBlurEase = easeInOutCubic(currentHeroProgress);

        const hScale = (1 - 0.04 * hMotionEase).toFixed(4);
        const hBlur = (5.5 * hBlurEase).toFixed(1);
        const hOpacity = (1 - 0.65 * hMotionEase).toFixed(2);
        const hTranslateY = -(hMotionEase * 32).toFixed(1);

        heroContent.style.transform = `translate3d(0, ${hTranslateY}px, 0) scale(${hScale})`;
        heroContent.style.filter = `blur(${hBlur}px)`;
        heroContent.style.opacity = hOpacity;
      }

      // --- 2. Stage Showcase Parallax (Card 1 & Card 2): Stacking Overlap ---
      if (baseCard && overlayCard) {
        const animStart = 0.05;
        const animEnd = 0.85;

        let p = 0;
        if (currentStageProgress > animStart) {
          p = Math.min(1, (currentStageProgress - animStart) / (animEnd - animStart));
        }

        const motionEase = easeInOutQuart(p);
        const blurEase = easeInOutQuart(p);

        // Card 1: GPU-accelerated blur via scrim opacity + subtle scale
        const scale = (1 - 0.045 * motionEase).toFixed(4);
        baseCard.style.transform = `translate3d(0, 0, 0) scale(${scale})`;

        if (baseScrim) {
          baseScrim.style.opacity = blurEase.toFixed(3);
        } else {
          baseCard.style.filter = `blur(${(6.0 * blurEase).toFixed(1)}px)`;
        }

        // Card 2: Pure GPU transform from 115% (clear Gap) to 0% (full overlap) with pronounced slow-in slow-out
        const translateY = ((1 - motionEase) * 115).toFixed(2);
        overlayCard.style.transform = `translate3d(0, ${translateY}%, 0)`;
      }

      // --- 3. Features -> Sponsor Parallax: Soft Blur & Overlapping Glide ---
      if (featuresSection && sponsorSection) {
        const sEase = easeInOutQuart(currentSponsorProgress);

        // Features softly scales and blurs as Sponsor glides into view
        const fScale = (1 - 0.035 * sEase).toFixed(4);
        const fBlur = (5.0 * sEase).toFixed(1);
        const fOpacity = (1 - 0.40 * sEase).toFixed(2);

        featuresSection.style.transform = `translate3d(0, 0, 0) scale(${fScale})`;
        featuresSection.style.filter = `blur(${fBlur}px)`;
        featuresSection.style.opacity = fOpacity;

        // Sponsor glides up smoothly and overlaps features
        const sponsorTranslateY = ((1 - sEase) * 65).toFixed(1);
        sponsorSection.style.transform = `translate3d(0, ${sponsorTranslateY}px, 0)`;
      }

      // Continue render loop if still interpolating
      if (
        Math.abs(targetHeroProgress - currentHeroProgress) > 0.0003 ||
        Math.abs(targetStageProgress - currentStageProgress) > 0.0003 ||
        Math.abs(targetSponsorProgress - currentSponsorProgress) > 0.0003
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
        if (overlayCard) {
          overlayCard.style.transform = '';
        }
        if (baseScrim) baseScrim.style.opacity = '';

        if (featuresSection) {
          featuresSection.style.transform = '';
          featuresSection.style.filter = '';
          featuresSection.style.opacity = '';
        }
        if (sponsorSection) {
          sponsorSection.style.transform = '';
        }
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

    // Initial setup
    measureLayout();
    requestRender();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initStageParallax);
  } else {
    initStageParallax();
  }
})();
