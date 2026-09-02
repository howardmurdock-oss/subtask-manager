// (sub)Task Manager - Website Interactive Script
document.addEventListener('DOMContentLoaded', () => {
  // --- 1. Theme Switcher ---
  const themeDots = document.querySelectorAll('.theme-dot');
  const savedTheme = localStorage.getItem('subtask_theme') || 'cyber';
  
  function applyTheme(themeName) {
    if (themeName === 'cyber') {
      document.documentElement.removeAttribute('data-theme');
    } else {
      document.documentElement.setAttribute('data-theme', themeName);
    }
    localStorage.setItem('subtask_theme', themeName);
    themeDots.forEach(dot => {
      dot.classList.toggle('active', dot.dataset.theme === themeName);
    });
  }

  applyTheme(savedTheme);

  themeDots.forEach(dot => {
    dot.addEventListener('click', () => {
      applyTheme(dot.dataset.theme);
    });
  });

  // --- 2. Showcase Window Tab Switching ---
  const tabBtns = document.querySelectorAll('.tab-btn');
  const viewContents = document.querySelectorAll('.view-content');

  function switchTab(viewId) {
    tabBtns.forEach(btn => btn.classList.toggle('active', btn.dataset.view === viewId));
    viewContents.forEach(view => view.classList.toggle('active', view.id === `view-${viewId}`));
  }

  tabBtns.forEach(btn => {
    btn.addEventListener('click', () => {
      switchTab(btn.dataset.view);
    });
  });

  // --- 3. Live Countdown Timer Simulation ---
  let totalSeconds = 900; // 15:00
  let currentSeconds = 842; // 14:02
  const timerDigits = document.querySelector('.timer-digits');
  const progressCircle = document.querySelector('.timer-progress-circle');

  function updateTimerUI() {
    if (!timerDigits || !progressCircle) return;
    const mins = Math.floor(currentSeconds / 60).toString().padStart(2, '0');
    const secs = (currentSeconds % 60).toString().padStart(2, '0');
    timerDigits.textContent = `${mins}:${secs}`;
    
    // Circle circumference approx 440 (2 * pi * 70)
    const ratio = currentSeconds / totalSeconds;
    const offset = 440 * (1 - ratio);
    progressCircle.style.strokeDashoffset = offset;
  }

  setInterval(() => {
    if (currentSeconds > 0) {
      currentSeconds--;
      updateTimerUI();
    }
  }, 1000);
  updateTimerUI();

  // --- 5. Interactive Directive Draw Simulator ---
  const sampleDirectives = [
    { tier: "Tier 1: Minor", bounty: "+15 Tokens", title: "Desk & Hydration Discipline", desc: "Clear your desk entirely, log your posture check, and drink 500ml water within 10 minutes." },
    { tier: "Tier 2: Routine", bounty: "+30 Tokens", title: "Focused 25-Min Sprint", desc: "No phone, zero social tabs. Deep focus sprint logged in the session timer." },
    { tier: "Tier 3: Intensive", bounty: "+50 Tokens", title: "Wall Sit & Posture Hold", desc: "3-minute continuous wall sit with focused breathing. Photo proof required." },
    { tier: "Tier 4: Strict", bounty: "+80 Tokens", title: "Cold Water Endurance", desc: "2-minute ice cold shower routine with immediate verification selfie timestamp." },
    { tier: "Tier 5: Absolute", bounty: "+150 Tokens", title: "Total Silence Isolation", desc: "1 hour zero entertainment lockdown. Kneeling posture drill with timer check-ins." }
  ];
  let directiveIndex = 2;
  const drawBtn = document.getElementById('btn-draw-next');
  if (drawBtn) {
    drawBtn.addEventListener('click', () => {
      directiveIndex = (directiveIndex + 1) % sampleDirectives.length;
      const d = sampleDirectives[directiveIndex];
      document.querySelector('.directive-header .tier-tag').textContent = d.tier;
      document.querySelector('.directive-header .bounty-tag').innerHTML = `★ ${d.bounty}`;
      document.querySelector('.directive-title').textContent = d.title;
      document.querySelector('.directive-desc').textContent = d.desc;
    });
  }

  // --- 6. FAQ Accordion ---
  const faqItems = document.querySelectorAll('.faq-item');
  faqItems.forEach(item => {
    const question = item.querySelector('.faq-question');
    question.addEventListener('click', () => {
      const isActive = item.classList.contains('active');
      faqItems.forEach(i => i.classList.remove('active'));
      if (!isActive) {
        item.classList.add('active');
      }
    });
  });

  // --- 7. Smooth Scroll for Navigation ---
  document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function(e) {
      const target = document.querySelector(this.getAttribute('href'));
      if (target) {
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    });
  });
});
