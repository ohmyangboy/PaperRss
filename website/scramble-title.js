class TextScramble {
  constructor(element, reduceMotion) {
    this.element = element;
    this.reduceMotion = reduceMotion;
    this.characters = '!@#$%^&*()_+-=[]{}|;:,.<>?/0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ¶§ØÆΞX∆';
    this.weights = [300, 400, 500, 600, 700, 800];
    this.fontFamilies = [
      'var(--font-serif)',
      'var(--font-mono)',
      "'Songti SC', 'STSong', serif",
      "'Kaiti SC', 'STKaiti', serif",
      'system-ui, sans-serif',
    ];
    this.frame = 0;
    this.frameRequest = null;
    this.queue = [];
    this.update = this.update.bind(this);
  }

  setText(newText) {
    cancelAnimationFrame(this.frameRequest);
    this.element.setAttribute('aria-label', newText);

    if (this.reduceMotion) {
      this.element.textContent = newText;
      return;
    }

    const oldText = this.element.textContent;
    const length = Math.max(oldText.length, newText.length);
    this.queue = [];

    for (let index = 0; index < length; index += 1) {
      const from = oldText[index] || '';
      const to = newText[index] || '';
      const start = Math.floor(Math.random() * 15);
      const end = start + Math.floor(Math.random() * 20) + 12;
      this.queue.push({
        from,
        to,
        start,
        end,
        settleEnd: 0,
        character: '',
        weight: this.randomWeight(),
        fontFamily: this.randomFontFamily(),
        settleWeight: this.randomWeight(),
        settleFontFamily: this.randomFontFamily(),
      });
    }

    this.scrambleEnd = Math.max(...this.queue.map((item) => item.end));
    for (const item of this.queue) {
      item.settleEnd = this.scrambleEnd + Math.floor(Math.random() * 12) + 8;
    }

    this.frame = 0;
    this.update();
  }

  update() {
    const fragment = document.createDocumentFragment();
    let complete = 0;

    for (const item of this.queue) {
      if (this.frame >= item.settleEnd) {
        complete += 1;
        fragment.append(document.createTextNode(item.to));
        continue;
      }

      if (this.frame >= this.scrambleEnd) {
        const settling = document.createElement('span');
        settling.className = 'settling-char';
        settling.setAttribute('aria-hidden', 'true');
        settling.textContent = item.to;
        settling.style.fontWeight = String(item.settleWeight);
        settling.style.fontFamily = item.settleFontFamily;
        fragment.append(settling);
        continue;
      }

      if (this.frame >= item.start && (!item.character || Math.random() < 0.3)) {
        item.character = this.randomCharacter();
        item.weight = this.randomWeight();
        item.fontFamily = this.randomFontFamily();
      }

      const scrambled = document.createElement('span');
      scrambled.className = 'scramble-char';
      scrambled.setAttribute('aria-hidden', 'true');
      scrambled.textContent = item.character || this.randomCharacter();
      scrambled.style.fontWeight = String(item.weight || this.randomWeight());
      scrambled.style.fontFamily = item.fontFamily || this.randomFontFamily();
      fragment.append(scrambled);
    }

    this.element.replaceChildren(fragment);
    if (complete === this.queue.length) {
      this.element.textContent = this.element.dataset.text;
      return;
    }

    this.frame += 1;
    this.frameRequest = requestAnimationFrame(this.update);
  }

  randomCharacter() {
    return this.characters[Math.floor(Math.random() * this.characters.length)];
  }

  randomWeight() {
    return this.weights[Math.floor(Math.random() * this.weights.length)];
  }

  randomFontFamily() {
    return this.fontFamilies[Math.floor(Math.random() * this.fontFamilies.length)];
  }
}

async function initializeTitleAnimation() {
  await document.fonts?.ready;

  const title = document.querySelector('.scramble-title');
  const targets = [...document.querySelectorAll('.scramble-target')];
  if (!title || targets.length === 0) return;

  const titleFontSize = Number.parseFloat(getComputedStyle(title).fontSize);
  for (const target of targets) {
    target.style.width = `${target.getBoundingClientRect().width / titleFontSize}em`;
  }
  title.style.height = `${title.getBoundingClientRect().height / titleFontSize}em`;

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const effects = targets.map((target) => new TextScramble(target, reduceMotion));

  function runTitleAnimation() {
    effects.forEach((effect, index) => {
      window.setTimeout(() => effect.setText(effect.element.dataset.text), index * 80);
    });
  }

  runTitleAnimation();
  title.addEventListener('click', runTitleAnimation);
}

initializeTitleAnimation();
