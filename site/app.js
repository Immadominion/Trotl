/* =====================================================================
   THROTL landing — interactions
   ===================================================================== */
(function () {
  'use strict';

  /* ------------------------------------------------------------------
     CTA TARGET — the web app game.
     Change this ONE line to repoint every "play" button on the page.
     Points at the deployed Flutter web app (app.throtl.fun). Could also
     be a path like '/play/' if the game is served alongside this site.
     ------------------------------------------------------------------ */
  var GAME_URL = 'https://app.throtl.fun';

  document.querySelectorAll('[data-cta]').forEach(function (a) {
    a.setAttribute('href', GAME_URL);
  });

  var reduceMotion = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---- sticky nav state ---- */
  var nav = document.getElementById('nav');
  function onScroll() {
    if (nav) nav.classList.toggle('scrolled', window.scrollY > 24);
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  /* ---- mobile menu ---- */
  var burger = document.getElementById('burger');
  if (burger && nav) {
    burger.addEventListener('click', function () { nav.classList.toggle('open'); });
    document.querySelectorAll('#navLinks a').forEach(function (a) {
      a.addEventListener('click', function () { nav.classList.remove('open'); });
    });
  }

  /* ---- seamless marquee: duplicate the track contents once so the
         -50% translate loops without a visible seam ---- */
  var ticker = document.getElementById('ticker');
  if (ticker) ticker.innerHTML += ticker.innerHTML;

  /* ---- speed lines inside the cockpit ---- */
  var sl = document.getElementById('speedlines');
  if (sl && !reduceMotion) {
    for (var i = 0; i < 6; i++) {
      var line = document.createElement('i');
      line.style.top = (8 + (i * 83) % 84) + '%';
      line.style.animationDuration = (0.5 + (i % 3) * 0.12).toFixed(2) + 's';
      line.style.animationDelay = (i * 0.09).toFixed(2) + 's';
      sl.appendChild(line);
    }
  }

  /* ---- scroll reveal ---- */
  var revealEls = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !reduceMotion) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
      });
    }, { threshold: 0.14, rootMargin: '0px 0px -8% 0px' });
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add('in'); });
  }

  /* ---- gentle parallax on the glow blobs ---- */
  var blobs = Array.prototype.slice.call(document.querySelectorAll('.blob'));
  if (blobs.length && !reduceMotion) {
    var ticking = false;
    window.addEventListener('scroll', function () {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(function () {
        var y = window.scrollY;
        blobs.forEach(function (b, idx) {
          var rate = (idx % 2 ? -0.04 : 0.06) * ((idx % 3) + 1);
          b.style.transform = (b.dataset.baseT || '') + ' translateY(' + (y * rate).toFixed(1) + 'px)';
        });
        ticking = false;
      });
    }, { passive: true });
    // preserve any inline transform (e.g. the centered finale blob)
    blobs.forEach(function (b) {
      var t = b.style.transform;
      if (t) b.dataset.baseT = t;
    });
  }

  /* ---- live-ish PnL flicker in the cockpit (cosmetic) ---- */
  var pnl = document.getElementById('pnl');
  if (pnl && !reduceMotion) {
    var base = 418.2;
    setInterval(function () {
      var v = base + (Math.sin(Date.now() / 900) * 9) + (Math.random() * 4 - 2);
      pnl.textContent = (v >= 0 ? '+$' : '-$') + Math.abs(v).toFixed(2);
    }, 700);
  }

  /* ---- tilt the phone toward the cursor (desktop only) ---- */
  var phone = document.getElementById('phone');
  if (phone && !reduceMotion && window.matchMedia('(hover: hover)').matches) {
    var stage = phone.parentElement;
    stage.addEventListener('mousemove', function (e) {
      var r = stage.getBoundingClientRect();
      var dx = (e.clientX - (r.left + r.width / 2)) / r.width;
      var dy = (e.clientY - (r.top + r.height / 2)) / r.height;
      phone.style.transform = 'rotate(2deg) rotateY(' + (dx * 7).toFixed(2) +
        'deg) rotateX(' + (-dy * 6).toFixed(2) + 'deg)';
    });
    stage.addEventListener('mouseleave', function () { phone.style.transform = ''; });
  }

  /* ---- copy program id ---- */
  var copyBtn = document.getElementById('copyBtn');
  if (copyBtn) {
    copyBtn.addEventListener('click', function () {
      var text = copyBtn.getAttribute('data-copy');
      var done = function () {
        var old = copyBtn.textContent;
        copyBtn.textContent = 'COPIED ✓';
        setTimeout(function () { copyBtn.textContent = old; }, 1400);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(done);
      } else { done(); }
    });
  }
})();
